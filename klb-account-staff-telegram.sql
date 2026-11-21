-- =====================================================================
-- KLB STORE: ACCOUNT / STAFF / PROMO / TELEGRAM UPDATE
-- Run after the existing KLB auth, wallet, marketplace escrow and trust migrations.
-- Safe to re-run. Does not delete users, wallets, listings, orders or chats.
-- Creator account UUID: aaa71905-fc0d-4e72-9202-482141757e28
-- =====================================================================

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.profiles') IS NULL
     OR to_regclass('public.marketplace_orders') IS NULL
     OR to_regclass('public.marketplace_chats') IS NULL
     OR to_regclass('public.marketplace_messages') IS NULL
     OR to_regclass('public.marketplace_reports') IS NULL
     OR to_regclass('public.marketplace_disputes') IS NULL THEN
    RAISE EXCEPTION 'KLB base tables are missing. Run the existing KLB marketplace and trust migrations first.';
  END IF;
  IF to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION 'public.is_admin() is missing. Install the KLB auth repair first.';
  END IF;
END;
$preflight$;

-- Moderator permissions and seller-trading restriction are separate from the account role.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS moderator_level smallint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS trading_disabled boolean NOT NULL DEFAULT false;

DO $profile_checks$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.profiles'::regclass
      AND conname = 'profiles_moderator_level_check'
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_moderator_level_check CHECK (moderator_level BETWEEN 0 AND 2);
  END IF;
END;
$profile_checks$;

CREATE OR REPLACE FUNCTION public.klb_is_owner()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT auth.uid() = 'aaa71905-fc0d-4e72-9202-482141757e28'::uuid;
$$;

CREATE OR REPLACE FUNCTION public.klb_is_moderator()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.status = 'active' AND p.moderator_level BETWEEN 1 AND 2
  );
$$;

CREATE OR REPLACE FUNCTION public.klb_is_moderator_level_two()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.status = 'active' AND p.moderator_level = 2
  );
$$;

CREATE OR REPLACE FUNCTION public.is_staff()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.is_admin() OR public.klb_is_moderator();
$$;

CREATE OR REPLACE FUNCTION public.klb_staff_access()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_profile public.profiles%ROWTYPE;
BEGIN
  SELECT * INTO v_profile FROM public.profiles WHERE id = auth.uid();
  IF NOT FOUND OR v_profile.status <> 'active' THEN
    RAISE EXCEPTION 'Staff access denied';
  END IF;
  IF v_profile.role <> 'admin' AND v_profile.moderator_level = 0 THEN
    RAISE EXCEPTION 'Staff access denied';
  END IF;
  RETURN jsonb_build_object(
    'role', v_profile.role,
    'moderator_level', v_profile.moderator_level,
    'is_admin', v_profile.role = 'admin',
    'is_owner', public.klb_is_owner()
  );
END;
$function$;

-- Protect privileged profile columns. Trusted server RPCs set this transaction-local marker
-- only after checking the caller's owner/staff permission.
CREATE OR REPLACE FUNCTION public.protect_profile_privileges()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF (
       NEW.role IS DISTINCT FROM OLD.role
       OR NEW.status IS DISTINCT FROM OLD.status
       OR NEW.moderator_level IS DISTINCT FROM OLD.moderator_level
       OR NEW.trading_disabled IS DISTINCT FROM OLD.trading_disabled
     )
     AND coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_admin()
     AND coalesce(current_setting('klb.internal_profile_action', true), '') <> '1'
  THEN
    RAISE EXCEPTION 'role/status/moderator changes are restricted';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS protect_profile_privileges_trigger ON public.profiles;
CREATE TRIGGER protect_profile_privileges_trigger
BEFORE UPDATE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.protect_profile_privileges();

-- A seller who has lost trading rights cannot create new listings.
CREATE OR REPLACE FUNCTION public.is_seller()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role IN ('seller', 'admin')
      AND p.status = 'active'
      AND NOT p.trading_disabled
  );
$$;

DROP POLICY IF EXISTS listings_seller_insert ON public.seller_listings;
CREATE POLICY listings_seller_insert
ON public.seller_listings FOR INSERT TO authenticated
WITH CHECK (
  seller_id = (SELECT auth.uid())
  AND EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = (SELECT auth.uid())
      AND p.role IN ('seller', 'admin')
      AND p.status = 'active'
      AND NOT p.trading_disabled
  )
);

-- Secure team presence and activity log.
CREATE TABLE IF NOT EXISTS public.klb_moderator_presence (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  current_page text NOT NULL DEFAULT 'admin'
);

CREATE TABLE IF NOT EXISTS public.klb_moderator_activity (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  moderator_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  action text NOT NULL,
  target_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS klb_moderator_activity_user_date_idx
  ON public.klb_moderator_activity(moderator_id, created_at DESC);

ALTER TABLE public.klb_moderator_presence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.klb_moderator_activity ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.klb_moderator_presence, public.klb_moderator_activity FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.klb_moderator_heartbeat(p_page text DEFAULT 'admin')
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NOT public.is_staff() THEN RAISE EXCEPTION 'Moderator only'; END IF;
  INSERT INTO public.klb_moderator_presence(user_id, last_seen_at, current_page)
  VALUES (auth.uid(), now(), left(coalesce(p_page, 'admin'), 80))
  ON CONFLICT (user_id) DO UPDATE
    SET last_seen_at = EXCLUDED.last_seen_at,
        current_page = EXCLUDED.current_page;
END;
$function$;

CREATE OR REPLACE FUNCTION public.klb_moderator_roster()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT public.klb_is_owner() THEN RAISE EXCEPTION 'Owner only'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'user_id', p.id,
    'username', p.username,
    'moderator_level', p.moderator_level,
    'online', coalesce(mp.last_seen_at > now() - interval '2 minutes', false),
    'last_seen', mp.last_seen_at,
    'current_page', mp.current_page,
    'actions_count', coalesce(ac.actions_count, 0),
    'last_action_at', ac.last_action_at
  ) ORDER BY p.moderator_level DESC, p.username), '[]'::jsonb)
  INTO v_result
  FROM public.profiles p
  LEFT JOIN public.klb_moderator_presence mp ON mp.user_id = p.id
  LEFT JOIN LATERAL (
    SELECT count(*)::bigint AS actions_count, max(created_at) AS last_action_at
    FROM public.klb_moderator_activity a WHERE a.moderator_id = p.id
  ) ac ON true
  WHERE p.moderator_level BETWEEN 1 AND 2;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.klb_assign_moderator(p_username text, p_level integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_target uuid;
BEGIN
  IF NOT public.klb_is_owner() THEN RAISE EXCEPTION 'Owner only'; END IF;
  IF p_level NOT BETWEEN 0 AND 2 THEN RAISE EXCEPTION 'Invalid moderator level'; END IF;
  SELECT id INTO v_target FROM public.profiles WHERE lower(username) = lower(trim(p_username));
  IF v_target IS NULL THEN RAISE EXCEPTION 'Profile not found'; END IF;
  IF v_target = auth.uid() THEN RAISE EXCEPTION 'Owner cannot be assigned as moderator'; END IF;
  PERFORM set_config('klb.internal_profile_action', '1', true);
  UPDATE public.profiles SET moderator_level = p_level WHERE id = v_target;
  INSERT INTO public.klb_moderator_activity(moderator_id, action, target_id)
  VALUES (auth.uid(), CASE WHEN p_level = 0 THEN 'moderator_revoked' ELSE 'moderator_assigned_level_' || p_level::text END, v_target);
END;
$function$;

-- Telegram identity data is private and never exposed through the public profiles view.
CREATE TABLE IF NOT EXISTS public.klb_telegram_accounts (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  telegram_user_id text NOT NULL UNIQUE,
  telegram_chat_id text,
  telegram_username text,
  linked_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.klb_telegram_link_codes (
  code uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '15 minutes'),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.klb_telegram_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.klb_telegram_link_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.klb_telegram_accounts, public.klb_telegram_link_codes FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.klb_create_telegram_link_code()
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_code uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  DELETE FROM public.klb_telegram_link_codes WHERE user_id = auth.uid() OR expires_at < now();
  INSERT INTO public.klb_telegram_link_codes(user_id) VALUES (auth.uid()) RETURNING code INTO v_code;
  RETURN v_code;
END;
$function$;

-- Promo-code management is available to admins and moderator level 2. Redemption is a separate
-- checkout change and is intentionally not activated by this management-only update.
CREATE TABLE IF NOT EXISTS public.marketplace_promo_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE CHECK (code = upper(code) AND code ~ '^[A-Z0-9_-]{3,32}$'),
  discount_type text NOT NULL CHECK (discount_type IN ('percent', 'fixed')),
  discount_value numeric(12,2) NOT NULL CHECK (discount_value > 0),
  max_uses integer CHECK (max_uses IS NULL OR max_uses > 0),
  used_count integer NOT NULL DEFAULT 0 CHECK (used_count >= 0),
  expires_at timestamptz,
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.marketplace_promo_codes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS klb_promo_codes_staff_read ON public.marketplace_promo_codes;
CREATE POLICY klb_promo_codes_staff_read ON public.marketplace_promo_codes
FOR SELECT TO authenticated USING (public.is_admin() OR public.klb_is_moderator_level_two());
DROP POLICY IF EXISTS klb_promo_codes_staff_insert ON public.marketplace_promo_codes;
CREATE POLICY klb_promo_codes_staff_insert ON public.marketplace_promo_codes
FOR INSERT TO authenticated WITH CHECK (public.is_admin() OR public.klb_is_moderator_level_two());
DROP POLICY IF EXISTS klb_promo_codes_staff_update ON public.marketplace_promo_codes;
CREATE POLICY klb_promo_codes_staff_update ON public.marketplace_promo_codes
FOR UPDATE TO authenticated USING (public.is_admin() OR public.klb_is_moderator_level_two())
WITH CHECK (public.is_admin() OR public.klb_is_moderator_level_two());
GRANT SELECT, INSERT, UPDATE ON public.marketplace_promo_codes TO authenticated;

-- Staff read access for complaints, disputes and the associated transcript.
DROP POLICY IF EXISTS klb_marketplace_reports_participant_admin_read ON public.marketplace_reports;
CREATE POLICY klb_marketplace_reports_participant_admin_read
ON public.marketplace_reports FOR SELECT TO authenticated
USING (reporter_id = (SELECT auth.uid()) OR public.is_staff());

DROP POLICY IF EXISTS klb_marketplace_disputes_participant_admin_read ON public.marketplace_disputes;
CREATE POLICY klb_marketplace_disputes_participant_admin_read
ON public.marketplace_disputes FOR SELECT TO authenticated
USING (buyer_id = (SELECT auth.uid()) OR seller_id = (SELECT auth.uid()) OR public.is_staff());

DROP POLICY IF EXISTS klb_marketplace_chats_participants_read ON public.marketplace_chats;
CREATE POLICY klb_marketplace_chats_participants_read
ON public.marketplace_chats FOR SELECT TO authenticated
USING (buyer_id = (SELECT auth.uid()) OR seller_id = (SELECT auth.uid()) OR public.is_staff());

DROP POLICY IF EXISTS klb_marketplace_messages_participants_read ON public.marketplace_messages;
CREATE POLICY klb_marketplace_messages_participants_read
ON public.marketplace_messages FOR SELECT TO authenticated
USING (
  public.is_staff()
  OR EXISTS (
    SELECT 1 FROM public.marketplace_chats c
    WHERE c.id = chat_id
      AND (c.buyer_id = (SELECT auth.uid()) OR c.seller_id = (SELECT auth.uid()))
  )
);

DROP POLICY IF EXISTS klb_evidence_owner_or_admin_read ON storage.objects;
CREATE POLICY klb_evidence_owner_or_admin_read
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'klb-report-evidence'
  AND ((storage.foldername(name))[1] = (SELECT auth.uid())::text OR public.is_staff())
);

-- Staff can act on account reports. Moderators can only block an account or disable its trading;
-- the owner/admin can use the same actions. A staff member cannot sanction an admin/owner.
CREATE OR REPLACE FUNCTION public.klb_staff_resolve_report(
  p_report_id uuid,
  p_action text,
  p_note text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_report public.marketplace_reports%ROWTYPE;
  v_target public.profiles%ROWTYPE;
BEGIN
  IF NOT public.is_staff() THEN RAISE EXCEPTION 'Moderator only'; END IF;
  IF p_action NOT IN ('block', 'remove_seller', 'reject') THEN RAISE EXCEPTION 'Invalid report action'; END IF;
  SELECT * INTO v_report FROM public.marketplace_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND OR v_report.status <> 'pending' THEN RAISE EXCEPTION 'Report unavailable'; END IF;
  SELECT * INTO v_target FROM public.profiles WHERE id = v_report.target_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Profile not found'; END IF;
  IF (v_target.role = 'admin' OR v_report.target_user_id = 'aaa71905-fc0d-4e72-9202-482141757e28'::uuid)
     AND p_action <> 'reject' THEN
    RAISE EXCEPTION 'Cannot apply sanctions to the store owner or administrator';
  END IF;

  IF p_action = 'block' THEN
    PERFORM set_config('klb.internal_profile_action', '1', true);
    UPDATE public.profiles SET status = 'blocked' WHERE id = v_report.target_user_id;
    UPDATE public.seller_listings SET status = 'paused', updated_at = now()
      WHERE seller_id = v_report.target_user_id AND status IN ('active', 'pending');
    UPDATE public.marketplace_reports SET status = 'approved_blocked', resolution_note = trim(coalesce(p_note,'')),
      resolved_by = auth.uid(), resolved_at = now() WHERE id = p_report_id;
  ELSIF p_action = 'remove_seller' THEN
    IF v_target.role <> 'seller' THEN RAISE EXCEPTION 'Target user is not an active seller'; END IF;
    PERFORM set_config('klb.internal_profile_action', '1', true);
    UPDATE public.profiles SET trading_disabled = true WHERE id = v_report.target_user_id;
    UPDATE public.seller_listings SET status = 'paused', updated_at = now()
      WHERE seller_id = v_report.target_user_id AND status IN ('active', 'pending');
    UPDATE public.marketplace_reports SET status = 'approved_seller_removed', resolution_note = trim(coalesce(p_note,'')),
      resolved_by = auth.uid(), resolved_at = now() WHERE id = p_report_id;
  ELSE
    UPDATE public.marketplace_reports SET status = 'rejected', resolution_note = trim(coalesce(p_note,'')),
      resolved_by = auth.uid(), resolved_at = now() WHERE id = p_report_id;
  END IF;

  IF v_report.chat_id IS NOT NULL THEN
    INSERT INTO public.marketplace_messages(chat_id, sender_id, body)
    VALUES (v_report.chat_id, auth.uid(),
      CASE p_action WHEN 'block' THEN 'Администрация рассмотрела жалобу и заблокировала аккаунт.'
        WHEN 'remove_seller' THEN 'Администрация рассмотрела жалобу и приостановила право торговли.'
        ELSE 'Администрация рассмотрела жалобу и не обнаружила достаточных оснований для санкций.' END
      || CASE WHEN trim(coalesce(p_note,'')) <> '' THEN ' Комментарий: ' || trim(p_note) ELSE '' END);
  END IF;
  INSERT INTO public.klb_moderator_activity(moderator_id, action, target_id)
  VALUES (auth.uid(), 'report_' || p_action, p_report_id);
END;
$function$;

-- Staff reviews disputes. Existing escrow/debit/refund semantics are preserved.
CREATE OR REPLACE FUNCTION public.klb_staff_resolve_dispute(
  p_dispute_id uuid,
  p_approve boolean,
  p_note text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_dispute public.marketplace_disputes%ROWTYPE;
  v_order public.marketplace_orders%ROWTYPE;
BEGIN
  IF NOT public.is_staff() THEN RAISE EXCEPTION 'Moderator only'; END IF;
  SELECT * INTO v_dispute FROM public.marketplace_disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND OR v_dispute.status <> 'open' THEN RAISE EXCEPTION 'Dispute unavailable'; END IF;
  SELECT * INTO v_order FROM public.marketplace_orders WHERE id = v_dispute.order_id FOR UPDATE;
  IF NOT FOUND OR v_order.status <> 'disputed' THEN RAISE EXCEPTION 'Disputed order unavailable'; END IF;

  IF p_approve THEN
    IF v_dispute.prior_order_status = 'completed' THEN
      INSERT INTO public.wallets(user_id) VALUES (v_order.seller_id) ON CONFLICT (user_id) DO NOTHING;
      INSERT INTO public.wallets(user_id) VALUES (v_order.buyer_id) ON CONFLICT (user_id) DO NOTHING;
      UPDATE public.wallets SET available = available - v_order.gross_amount, updated_at = now()
        WHERE user_id = v_order.seller_id;
      UPDATE public.wallets SET available = available + v_order.gross_amount, updated_at = now()
        WHERE user_id = v_order.buyer_id;
      INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
      VALUES
        (v_order.seller_id, 'dispute_chargeback', -v_order.gross_amount, v_order.id, 'Полное списание по одобренному спору'),
        (v_order.buyer_id, 'dispute_refund', v_order.gross_amount, v_order.id, 'Возврат по одобренному спору');
      -- The commission already paid to the platform is not reversed.
    ELSE
      UPDATE public.wallets SET escrow = escrow - v_order.gross_amount,
        available = available + v_order.gross_amount, updated_at = now()
        WHERE user_id = v_order.buyer_id AND escrow >= v_order.gross_amount;
      IF NOT FOUND THEN RAISE EXCEPTION 'Escrow balance mismatch'; END IF;
      INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
      VALUES (v_order.buyer_id, 'dispute_refund', v_order.gross_amount, v_order.id, 'Возврат из эскроу по одобренному спору');
    END IF;
    UPDATE public.marketplace_orders SET status = 'refunded', updated_at = now() WHERE id = v_order.id;
    UPDATE public.marketplace_disputes SET status = 'approved', resolution_note = trim(coalesce(p_note,'')),
      resolved_by = auth.uid(), resolved_at = now() WHERE id = p_dispute_id;
    INSERT INTO public.marketplace_messages(chat_id, sender_id, body)
    VALUES (v_dispute.chat_id, auth.uid(),
      'Администрация одобрила спор. Покупателю возвращено ' || v_order.gross_amount::text || ' ₽.'
      || CASE WHEN v_dispute.prior_order_status = 'completed'
        THEN ' С продавца списана полная сумма заказа; комиссия 5% остаётся у KLB STORE.'
        ELSE ' Средства возвращены из эскроу; выплата продавцу не производилась.' END
      || CASE WHEN trim(coalesce(p_note,'')) <> '' THEN ' Комментарий: ' || trim(p_note) ELSE '' END);
  ELSE
    UPDATE public.marketplace_orders SET status = v_dispute.prior_order_status, updated_at = now() WHERE id = v_order.id;
    UPDATE public.marketplace_disputes SET status = 'rejected', resolution_note = trim(coalesce(p_note,'')),
      resolved_by = auth.uid(), resolved_at = now() WHERE id = p_dispute_id;
    INSERT INTO public.marketplace_messages(chat_id, sender_id, body)
    VALUES (v_dispute.chat_id, auth.uid(),
      'Администрация рассмотрела спор и не обнаружила нарушений. Возврат средств не производится; сделка продолжает действовать.'
      || CASE WHEN trim(coalesce(p_note,'')) <> '' THEN ' Комментарий: ' || trim(p_note) ELSE '' END);
  END IF;
  INSERT INTO public.klb_moderator_activity(moderator_id, action, target_id)
  VALUES (auth.uid(), CASE WHEN p_approve THEN 'dispute_approved' ELSE 'dispute_rejected' END, p_dispute_id);
END;
$function$;

-- Owner-only detailed activity feed for the moderation team.
CREATE OR REPLACE FUNCTION public.klb_moderator_activity_feed()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT public.klb_is_owner() THEN RAISE EXCEPTION 'Owner only'; END IF;
  SELECT coalesce(jsonb_agg(q.row_data ORDER BY q.created_at DESC), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      a.created_at,
      jsonb_build_object(
        'id', a.id,
        'moderator_id', a.moderator_id,
        'moderator', p.username,
        'action', a.action,
        'action_label', CASE a.action
          WHEN 'report_block' THEN 'Заблокировал пользователя'
          WHEN 'report_remove_seller' THEN 'Запретил торговлю'
          WHEN 'report_reject' THEN 'Отклонил жалобу'
          WHEN 'dispute_approved' THEN 'Одобрил спор и возврат'
          WHEN 'dispute_rejected' THEN 'Отказал в споре'
          WHEN 'moderator_revoked' THEN 'Снял права модератора'
          WHEN 'moderator_assigned_level_1' THEN 'Назначил модератора 1 уровня'
          WHEN 'moderator_assigned_level_2' THEN 'Назначил модератора 2 уровня'
          WHEN 'promo_created' THEN 'Создал промокод'
          WHEN 'promo_enabled' THEN 'Включил промокод'
          WHEN 'promo_disabled' THEN 'Отключил промокод'
          ELSE a.action END,
        'target', coalesce(t.username, a.target_id::text),
        'created_at', a.created_at
      ) AS row_data
    FROM public.klb_moderator_activity a
    JOIN public.profiles p ON p.id = a.moderator_id
    LEFT JOIN public.profiles t ON t.id = a.target_id
    ORDER BY a.created_at DESC
    LIMIT 100
  ) q;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.klb_log_moderator_activity(
  p_action text,
  p_target_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NOT (public.is_admin() OR public.klb_is_moderator_level_two()) THEN
    RAISE EXCEPTION 'Moderator level 2 required';
  END IF;
  IF p_action NOT IN ('promo_created', 'promo_enabled', 'promo_disabled') THEN
    RAISE EXCEPTION 'Invalid activity action';
  END IF;
  INSERT INTO public.klb_moderator_activity(moderator_id, action, target_id)
  VALUES (auth.uid(), p_action, p_target_id);
END;
$function$;

-- Least-privilege function grants.
REVOKE ALL ON FUNCTION public.klb_staff_access() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_moderator_heartbeat(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_moderator_roster() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_moderator_activity_feed() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_log_moderator_activity(text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_assign_moderator(text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_create_telegram_link_code() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_staff_resolve_report(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_staff_resolve_dispute(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.klb_staff_access() TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_moderator_heartbeat(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_moderator_roster() TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_moderator_activity_feed() TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_log_moderator_activity(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_assign_moderator(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_create_telegram_link_code() TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_staff_resolve_report(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_staff_resolve_dispute(uuid, boolean, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verification summary
SELECT 'profiles' AS item, column_name AS detail
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'profiles'
  AND column_name IN ('moderator_level', 'trading_disabled')
UNION ALL
SELECT 'function', p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('klb_staff_access','klb_moderator_heartbeat','klb_moderator_roster','klb_moderator_activity_feed','klb_log_moderator_activity','klb_assign_moderator','klb_create_telegram_link_code','klb_staff_resolve_report','klb_staff_resolve_dispute')
ORDER BY 1,2;
