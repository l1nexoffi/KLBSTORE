-- =====================================================================
-- KLB STORE: PUBLIC PROFILES + REVIEWS + ACCOUNT REPORTS + ORDER DISPUTES
-- + ADMIN FINANCIAL STATS
-- Run AFTER marketplace-escrow-chat.sql as postgres / project owner.
-- Safe to re-run. No accounts, listings, messages, orders or wallets are deleted.
-- =====================================================================

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.profiles') IS NULL
     OR to_regclass('public.marketplace_orders') IS NULL
     OR to_regclass('public.marketplace_chats') IS NULL
     OR to_regclass('public.marketplace_messages') IS NULL
     OR to_regclass('public.wallets') IS NULL
     OR to_regclass('public.wallet_ledger') IS NULL
     OR to_regclass('public.platform_commissions') IS NULL THEN
    RAISE EXCEPTION 'KLB marketplace tables are missing. Run marketplace-escrow-chat.sql first.';
  END IF;
  IF to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION 'public.is_admin() is missing.';
  END IF;
END;
$preflight$;

-- Sellers may incur a negative available balance after an approved chargeback.
-- Checkout and withdrawals still require available >= the requested amount.
DO $allow_seller_debt$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.wallets'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%available%'
      AND pg_get_constraintdef(oid) ILIKE '%>=%'
      AND pg_get_constraintdef(oid) ILIKE '%0%'
  LOOP
    EXECUTE format('ALTER TABLE public.wallets DROP CONSTRAINT %I', c.conname);
  END LOOP;
END;
$allow_seller_debt$;

-- Add immutable audit operations for refunds and seller chargebacks.
DO $ledger_ops$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.wallet_ledger'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%operation%'
  LOOP
    EXECUTE format('ALTER TABLE public.wallet_ledger DROP CONSTRAINT %I', c.conname);
  END LOOP;
  ALTER TABLE public.wallet_ledger
    ADD CONSTRAINT wallet_ledger_operation_check
    CHECK (operation IN (
      'deposit', 'withdrawal_reserve', 'withdrawal_refund', 'withdrawal_paid',
      'purchase', 'purchase_escrow', 'sale', 'commission', 'adjustment',
      'dispute_refund', 'dispute_chargeback'
    ));
END;
$ledger_ops$;

-- Orders can be temporarily disputed or finally refunded.
DO $order_status_check$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.marketplace_orders'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE public.marketplace_orders DROP CONSTRAINT %I', c.conname);
  END LOOP;
  ALTER TABLE public.marketplace_orders
    ADD CONSTRAINT marketplace_orders_status_check
    CHECK (status IN ('paid', 'seller_completed', 'completed', 'disputed', 'refunded'));
END;
$order_status_check$;

-- Buyer reviews a seller after a completed order. One review per order.
CREATE TABLE IF NOT EXISTS public.marketplace_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.marketplace_orders(id) ON DELETE RESTRICT,
  reviewer_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  seller_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  rating integer NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment text NOT NULL DEFAULT '' CHECK (length(comment) <= 1500),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS marketplace_reviews_seller_idx
  ON public.marketplace_reviews(seller_id, created_at DESC);

-- Account reports submitted from a profile or a participant chat.
CREATE TABLE IF NOT EXISTS public.marketplace_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  target_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  chat_id uuid REFERENCES public.marketplace_chats(id) ON DELETE SET NULL,
  order_id uuid REFERENCES public.marketplace_orders(id) ON DELETE SET NULL,
  description text NOT NULL CHECK (length(trim(description)) BETWEEN 10 AND 2000),
  evidence_path text,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved_blocked', 'approved_seller_removed', 'rejected')),
  resolution_note text NOT NULL DEFAULT '',
  resolved_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  CHECK (reporter_id <> target_user_id)
);
CREATE INDEX IF NOT EXISTS marketplace_reports_status_idx
  ON public.marketplace_reports(status, created_at DESC);
CREATE INDEX IF NOT EXISTS marketplace_reports_target_idx
  ON public.marketplace_reports(target_user_id, created_at DESC);

-- A dispute can only be raised once for an order. The previous order state is
-- stored so the admin can return it to the correct state when rejecting a dispute.
CREATE TABLE IF NOT EXISTS public.marketplace_disputes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.marketplace_orders(id) ON DELETE RESTRICT,
  chat_id uuid NOT NULL REFERENCES public.marketplace_chats(id) ON DELETE RESTRICT,
  buyer_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  seller_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  opened_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  prior_order_status text NOT NULL
    CHECK (prior_order_status IN ('paid', 'seller_completed', 'completed')),
  reason text NOT NULL CHECK (length(trim(reason)) BETWEEN 10 AND 2000),
  evidence_path text,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'approved', 'rejected')),
  resolution_note text NOT NULL DEFAULT '',
  resolved_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);
CREATE INDEX IF NOT EXISTS marketplace_disputes_status_idx
  ON public.marketplace_disputes(status, created_at DESC);

ALTER TABLE public.marketplace_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_disputes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS klb_marketplace_reviews_public_read ON public.marketplace_reviews;
CREATE POLICY klb_marketplace_reviews_public_read
ON public.marketplace_reviews FOR SELECT TO authenticated
USING (true);

DROP POLICY IF EXISTS klb_marketplace_reports_participant_admin_read ON public.marketplace_reports;
CREATE POLICY klb_marketplace_reports_participant_admin_read
ON public.marketplace_reports FOR SELECT TO authenticated
USING (reporter_id = (SELECT auth.uid()) OR public.is_admin());

DROP POLICY IF EXISTS klb_marketplace_disputes_participant_admin_read ON public.marketplace_disputes;
CREATE POLICY klb_marketplace_disputes_participant_admin_read
ON public.marketplace_disputes FOR SELECT TO authenticated
USING (buyer_id = (SELECT auth.uid()) OR seller_id = (SELECT auth.uid()) OR public.is_admin());

-- Admins may inspect the participant conversation when reviewing a dispute.
DROP POLICY IF EXISTS klb_marketplace_chats_participants_read ON public.marketplace_chats;
CREATE POLICY klb_marketplace_chats_participants_read
ON public.marketplace_chats FOR SELECT TO authenticated
USING (buyer_id = (SELECT auth.uid()) OR seller_id = (SELECT auth.uid()) OR public.is_admin());

DROP POLICY IF EXISTS klb_marketplace_messages_participants_read ON public.marketplace_messages;
CREATE POLICY klb_marketplace_messages_participants_read
ON public.marketplace_messages FOR SELECT TO authenticated
USING (
  public.is_admin()
  OR EXISTS (
    SELECT 1 FROM public.marketplace_chats c
    WHERE c.id = chat_id
      AND (c.buyer_id = (SELECT auth.uid()) OR c.seller_id = (SELECT auth.uid()))
  )
);

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON public.marketplace_reviews, public.marketplace_reports,
  public.marketplace_disputes TO authenticated;

-- Private evidence storage. Users can upload only to their own folder;
-- only admins can read evidence and create signed URLs for review.
GRANT USAGE ON SCHEMA storage TO authenticated;
GRANT INSERT, SELECT ON storage.objects TO authenticated;

INSERT INTO storage.buckets (id, name, public)
VALUES ('klb-report-evidence', 'klb-report-evidence', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS klb_evidence_owner_insert ON storage.objects;
CREATE POLICY klb_evidence_owner_insert
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'klb-report-evidence'
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);

DROP POLICY IF EXISTS klb_evidence_admin_read ON storage.objects;
DROP POLICY IF EXISTS klb_evidence_owner_or_admin_read ON storage.objects;
CREATE POLICY klb_evidence_owner_or_admin_read
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'klb-report-evidence'
  AND ((storage.foldername(name))[1] = (SELECT auth.uid())::text OR public.is_admin())
);

-- Update own public profile description only; privileged columns remain guarded
-- by the existing protect_profile_privileges trigger.
GRANT SELECT ON public.profiles TO authenticated;
GRANT UPDATE (bio) ON public.profiles TO authenticated;

-- Create an account report. The caller can report another user, not themselves.
CREATE OR REPLACE FUNCTION public.create_marketplace_account_report(
  p_target_user_id uuid,
  p_description text,
  p_evidence_path text DEFAULT NULL,
  p_chat_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_reporter uuid := auth.uid();
  v_order_id uuid;
  v_other uuid;
  v_id uuid;
BEGIN
  IF v_reporter IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_target_user_id IS NULL OR p_target_user_id = v_reporter THEN
    RAISE EXCEPTION 'Cannot report yourself';
  END IF;
  IF length(trim(coalesce(p_description, ''))) < 10 OR length(p_description) > 2000 THEN
    RAISE EXCEPTION 'Report description must contain 10 to 2000 characters';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_target_user_id) THEN
    RAISE EXCEPTION 'Profile not found';
  END IF;
  IF p_evidence_path IS NOT NULL AND split_part(p_evidence_path, '/', 1) <> v_reporter::text THEN
    RAISE EXCEPTION 'Invalid evidence path';
  END IF;
  IF p_chat_id IS NOT NULL THEN
    SELECT CASE WHEN buyer_id = v_reporter THEN seller_id ELSE buyer_id END,
           order_id
      INTO v_other, v_order_id
    FROM public.marketplace_chats
    WHERE id = p_chat_id
      AND (buyer_id = v_reporter OR seller_id = v_reporter);
    IF NOT FOUND OR v_other <> p_target_user_id THEN
      RAISE EXCEPTION 'Chat participant unavailable';
    END IF;
  END IF;
  INSERT INTO public.marketplace_reports(
    reporter_id, target_user_id, chat_id, order_id, description, evidence_path
  ) VALUES (
    v_reporter, p_target_user_id, p_chat_id, v_order_id, trim(p_description), p_evidence_path
  ) RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;

-- Buyer opens a dispute against the order. Escrow remains untouched until admin review.
CREATE OR REPLACE FUNCTION public.create_marketplace_dispute(
  p_order_id uuid,
  p_reason text,
  p_evidence_path text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_order public.marketplace_orders%ROWTYPE;
  v_chat_id uuid;
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF length(trim(coalesce(p_reason, ''))) < 10 OR length(p_reason) > 2000 THEN
    RAISE EXCEPTION 'Dispute reason must contain 10 to 2000 characters';
  END IF;
  SELECT * INTO v_order
  FROM public.marketplace_orders
  WHERE id = p_order_id
  FOR UPDATE;
  IF NOT FOUND OR v_order.buyer_id <> auth.uid() THEN RAISE EXCEPTION 'Order unavailable'; END IF;
  IF v_order.status NOT IN ('paid', 'seller_completed', 'completed') THEN
    RAISE EXCEPTION 'This order cannot be disputed';
  END IF;
  IF p_evidence_path IS NOT NULL AND split_part(p_evidence_path, '/', 1) <> auth.uid()::text THEN
    RAISE EXCEPTION 'Invalid evidence path';
  END IF;
  SELECT id INTO v_chat_id FROM public.marketplace_chats WHERE order_id = p_order_id;
  IF v_chat_id IS NULL THEN RAISE EXCEPTION 'Order chat not found'; END IF;

  INSERT INTO public.marketplace_disputes(
    order_id, chat_id, buyer_id, seller_id, opened_by, prior_order_status, reason, evidence_path
  ) VALUES (
    v_order.id, v_chat_id, v_order.buyer_id, v_order.seller_id, auth.uid(),
    v_order.status, trim(p_reason), p_evidence_path
  ) RETURNING id INTO v_id;

  UPDATE public.marketplace_orders
  SET status = 'disputed', updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.marketplace_messages(chat_id, sender_id, body)
  VALUES (v_chat_id, auth.uid(), 'Покупатель открыл спор. Администрация рассмотрит обращение.');
  RETURN v_id;
END;
$function$;

-- Seller review is accepted only after a completed transaction and can be sent once.
CREATE OR REPLACE FUNCTION public.create_marketplace_review(
  p_order_id uuid,
  p_rating integer,
  p_comment text DEFAULT ''
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_order public.marketplace_orders%ROWTYPE;
  v_id uuid;
  v_chat_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN RAISE EXCEPTION 'Rating must be from 1 to 5'; END IF;
  IF length(coalesce(p_comment, '')) > 1500 THEN RAISE EXCEPTION 'Review is too long'; END IF;
  SELECT * INTO v_order FROM public.marketplace_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.buyer_id <> auth.uid() THEN RAISE EXCEPTION 'Order unavailable'; END IF;
  IF v_order.status <> 'completed' THEN RAISE EXCEPTION 'Review is available only after a completed order'; END IF;

  INSERT INTO public.marketplace_reviews(order_id, reviewer_id, seller_id, rating, comment)
  VALUES (v_order.id, auth.uid(), v_order.seller_id, p_rating, trim(coalesce(p_comment, '')))
  RETURNING id INTO v_id;

  SELECT id INTO v_chat_id FROM public.marketplace_chats WHERE order_id = p_order_id;
  IF v_chat_id IS NOT NULL THEN
    INSERT INTO public.marketplace_messages(chat_id, sender_id, body)
    VALUES (v_chat_id, auth.uid(), 'Покупатель оставил отзыв продавцу: ' || p_rating::text || '/5.');
  END IF;
  RETURN v_id;
END;
$function$;

-- Admin resolves an account report: block user, remove selling ability, or reject.
CREATE OR REPLACE FUNCTION public.admin_resolve_marketplace_report(
  p_report_id uuid,
  p_action text,
  p_note text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_report public.marketplace_reports%ROWTYPE;
  v_role text;
  v_default_role text;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_action IS NULL OR p_action NOT IN ('block', 'remove_seller', 'reject') THEN RAISE EXCEPTION 'Invalid report action'; END IF;
  SELECT * INTO v_report FROM public.marketplace_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND OR v_report.status <> 'pending' THEN RAISE EXCEPTION 'Report unavailable'; END IF;

  SELECT role INTO v_role FROM public.profiles WHERE id = v_report.target_user_id FOR UPDATE;
  IF v_role = 'admin' AND p_action <> 'reject' THEN RAISE EXCEPTION 'Cannot apply user sanctions to an administrator'; END IF;

  IF p_action = 'block' THEN
    UPDATE public.profiles SET status = 'blocked' WHERE id = v_report.target_user_id;
    UPDATE public.seller_listings SET status = 'paused', updated_at = now()
    WHERE seller_id = v_report.target_user_id AND status IN ('active', 'pending');
    UPDATE public.marketplace_reports
    SET status = 'approved_blocked', resolution_note = trim(coalesce(p_note, '')),
        resolved_by = auth.uid(), resolved_at = now()
    WHERE id = p_report_id;
  ELSIF p_action = 'remove_seller' THEN
    SELECT substring(column_default FROM $$^'([^']+)'$$)
      INTO v_default_role
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = 'role';
    IF v_default_role IS NULL THEN
      SELECT CASE WHEN bool_or(pg_get_constraintdef(oid) ILIKE '%buyer%') THEN 'buyer' ELSE 'user' END
      INTO v_default_role
      FROM pg_constraint
      WHERE conrelid = 'public.profiles'::regclass AND contype = 'c'
        AND pg_get_constraintdef(oid) ILIKE '%role%';
    END IF;
    v_default_role := coalesce(v_default_role, 'user');
    IF v_role <> 'seller' THEN RAISE EXCEPTION 'Target user is not an active seller'; END IF;
    UPDATE public.profiles SET role = v_default_role WHERE id = v_report.target_user_id;
    UPDATE public.seller_listings SET status = 'paused', updated_at = now()
    WHERE seller_id = v_report.target_user_id AND status IN ('active', 'pending');
    UPDATE public.marketplace_reports
    SET status = 'approved_seller_removed', resolution_note = trim(coalesce(p_note, '')),
        resolved_by = auth.uid(), resolved_at = now()
    WHERE id = p_report_id;
  ELSE
    UPDATE public.marketplace_reports
    SET status = 'rejected', resolution_note = trim(coalesce(p_note, '')),
        resolved_by = auth.uid(), resolved_at = now()
    WHERE id = p_report_id;
  END IF;

  IF v_report.chat_id IS NOT NULL THEN
    INSERT INTO public.marketplace_messages(chat_id, sender_id, body)
    VALUES (v_report.chat_id, auth.uid(),
      CASE p_action
        WHEN 'block' THEN 'Администрация рассмотрела жалобу и применила блокировку аккаунта.'
        WHEN 'remove_seller' THEN 'Администрация рассмотрела жалобу и ограничила право торговли.'
        ELSE 'Администрация рассмотрела жалобу и не обнаружила достаточных оснований для санкций.'
      END || CASE WHEN coalesce(trim(p_note), '') <> '' THEN ' Комментарий: ' || trim(p_note) ELSE '' END);
  END IF;
END;
$function$;

-- Admin resolves a dispute. If the seller was already paid, debit the full gross
-- amount (not net) and refund the buyer. The original 5% commission is retained.
-- Therefore a 100 ₽ sale paid out as 95 ₽ followed by a successful dispute leaves
-- the seller at -5 ₽ if the 95 ₽ is still on their account.
CREATE OR REPLACE FUNCTION public.admin_resolve_marketplace_dispute(
  p_dispute_id uuid,
  p_approve boolean,
  p_note text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_dispute public.marketplace_disputes%ROWTYPE;
  v_order public.marketplace_orders%ROWTYPE;
  v_chat_id uuid;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO v_dispute FROM public.marketplace_disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND OR v_dispute.status <> 'open' THEN RAISE EXCEPTION 'Dispute unavailable'; END IF;
  SELECT * INTO v_order FROM public.marketplace_orders WHERE id = v_dispute.order_id FOR UPDATE;
  IF NOT FOUND OR v_order.status <> 'disputed' THEN RAISE EXCEPTION 'Disputed order unavailable'; END IF;
  v_chat_id := v_dispute.chat_id;

  IF p_approve THEN
    IF v_dispute.prior_order_status = 'completed' THEN
      INSERT INTO public.wallets(user_id) VALUES (v_order.seller_id) ON CONFLICT (user_id) DO NOTHING;
      INSERT INTO public.wallets(user_id) VALUES (v_order.buyer_id) ON CONFLICT (user_id) DO NOTHING;
      UPDATE public.wallets
      SET available = available - v_order.gross_amount, updated_at = now()
      WHERE user_id = v_order.seller_id;
      UPDATE public.wallets
      SET available = available + v_order.gross_amount, updated_at = now()
      WHERE user_id = v_order.buyer_id;
      INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
      VALUES
        (v_order.seller_id, 'dispute_chargeback', -v_order.gross_amount, v_order.id,
         'Возврат покупателю по решению администрации: удержана полная сумма заказа'),
        (v_order.buyer_id, 'dispute_refund', v_order.gross_amount, v_order.id,
         'Возврат по одобренному спору');
      -- platform_commissions is intentionally not reversed: the 5% service fee remains.
    ELSE
      UPDATE public.wallets
      SET escrow = escrow - v_order.gross_amount,
          available = available + v_order.gross_amount,
          updated_at = now()
      WHERE user_id = v_order.buyer_id AND escrow >= v_order.gross_amount;
      IF NOT FOUND THEN RAISE EXCEPTION 'Escrow balance mismatch'; END IF;
      INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
      VALUES (v_order.buyer_id, 'dispute_refund', v_order.gross_amount, v_order.id,
              'Возврат из эскроу по одобренному спору');
    END IF;

    UPDATE public.marketplace_orders SET status = 'refunded', updated_at = now()
    WHERE id = v_order.id;
    UPDATE public.marketplace_disputes
    SET status = 'approved', resolution_note = trim(coalesce(p_note, '')),
        resolved_by = auth.uid(), resolved_at = now()
    WHERE id = p_dispute_id;
    INSERT INTO public.marketplace_messages(chat_id, sender_id, body)
    VALUES (v_chat_id, auth.uid(),
      'Администрация одобрила спор. Покупателю возвращено ' || v_order.gross_amount::text || ' ₽.'
      || CASE WHEN v_dispute.prior_order_status = 'completed'
          THEN ' С продавца удержана полная сумма заказа; комиссия сервиса 5% остаётся у KLB STORE.'
          ELSE ' Деньги возвращены из удержания; выплата продавцу не производилась.' END
      || CASE WHEN coalesce(trim(p_note), '') <> '' THEN ' Комментарий: ' || trim(p_note) ELSE '' END);
  ELSE
    UPDATE public.marketplace_orders
    SET status = v_dispute.prior_order_status, updated_at = now()
    WHERE id = v_order.id;
    UPDATE public.marketplace_disputes
    SET status = 'rejected', resolution_note = trim(coalesce(p_note, '')),
        resolved_by = auth.uid(), resolved_at = now()
    WHERE id = p_dispute_id;
    INSERT INTO public.marketplace_messages(chat_id, sender_id, body)
    VALUES (v_chat_id, auth.uid(),
      'Администрация рассмотрела спор и не обнаружила нарушений. Возврат средств не производится; сделка продолжает действовать.'
      || CASE WHEN coalesce(trim(p_note), '') <> '' THEN ' Комментарий: ' || trim(p_note) ELSE '' END);
  END IF;
END;
$function$;

-- Public-safe counts and rating for a user's profile. No wallet or private fields exposed.
CREATE OR REPLACE FUNCTION public.marketplace_public_profile_stats(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_purchases integer;
  v_sales integer;
  v_rating numeric(3,2);
  v_reviews integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'Profile not found';
  END IF;
  SELECT count(*)::integer INTO v_purchases
  FROM public.marketplace_orders WHERE buyer_id = p_user_id AND status = 'completed';
  SELECT count(*)::integer INTO v_sales
  FROM public.marketplace_orders WHERE seller_id = p_user_id AND status = 'completed';
  SELECT coalesce(round(avg(rating)::numeric, 2), 0), count(*)::integer
  INTO v_rating, v_reviews
  FROM public.marketplace_reviews WHERE seller_id = p_user_id;
  RETURN jsonb_build_object(
    'completed_purchases', v_purchases,
    'completed_sales', v_sales,
    'average_rating', v_rating,
    'reviews_count', v_reviews
  );
END;
$function$;

-- Financial stats: gross confirmed transaction turnover and retained platform commission.
CREATE OR REPLACE FUNCTION public.marketplace_admin_financial_stats()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_turnover_7 numeric(14,2);
  v_turnover_30 numeric(14,2);
  v_profit_7 numeric(14,2);
  v_profit_30 numeric(14,2);
  v_orders_7 integer;
  v_orders_30 integer;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT coalesce(sum(gross_amount), 0), count(*)::integer
  INTO v_turnover_7, v_orders_7
  FROM public.marketplace_orders
  WHERE buyer_confirmed_at >= now() - interval '7 days'
    AND status IN ('completed', 'disputed');
  SELECT coalesce(sum(gross_amount), 0), count(*)::integer
  INTO v_turnover_30, v_orders_30
  FROM public.marketplace_orders
  WHERE buyer_confirmed_at >= now() - interval '30 days'
    AND status IN ('completed', 'disputed');
  SELECT coalesce(sum(commission_amount), 0)
  INTO v_profit_7
  FROM public.platform_commissions
  WHERE created_at >= now() - interval '7 days';
  SELECT coalesce(sum(commission_amount), 0)
  INTO v_profit_30
  FROM public.platform_commissions
  WHERE created_at >= now() - interval '30 days';
  RETURN jsonb_build_object(
    'turnover_7d', v_turnover_7,
    'turnover_30d', v_turnover_30,
    'commission_7d', v_profit_7,
    'commission_30d', v_profit_30,
    'orders_7d', v_orders_7,
    'orders_30d', v_orders_30
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.create_marketplace_account_report(uuid, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_marketplace_dispute(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_marketplace_review(uuid, integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_resolve_marketplace_report(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_resolve_marketplace_dispute(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.marketplace_public_profile_stats(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.marketplace_admin_financial_stats() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_marketplace_account_report(uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_dispute(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_review(uuid, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_marketplace_report(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_marketplace_dispute(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marketplace_public_profile_stats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marketplace_admin_financial_stats() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verification summary.
SELECT c.relname AS table_name, c.relrowsecurity AS rls_enabled
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('marketplace_reviews', 'marketplace_reports', 'marketplace_disputes')
ORDER BY c.relname;

SELECT p.proname AS function_name
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'create_marketplace_account_report', 'create_marketplace_dispute',
    'create_marketplace_review', 'admin_resolve_marketplace_report',
    'admin_resolve_marketplace_dispute', 'marketplace_public_profile_stats',
    'marketplace_admin_financial_stats'
  )
ORDER BY p.proname;
