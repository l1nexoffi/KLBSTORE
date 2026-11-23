-- =====================================================================
-- KLB STORE — PARTNER ROLES + REFERRAL PROMO CODES
-- Run AFTER the existing KLB marketplace migrations:
-- marketplace-escrow-chat.sql,
-- klb-account-staff-telegram.sql,
-- marketplace-promo-redemption.sql,
-- marketplace-trust-safety.sql.
--
-- What it does:
--   * Admin assigns/removes partner status by KLB username.
--   * Admin creates/edits/disables one active referral promo per partner.
--   * Customer receives the configured discount at checkout.
--   * Partner commission is calculated from the original listing subtotal
--     (before the customer discount) and credited only after buyer confirms
--     successful delivery/completion.
--   * Approved post-completion disputes reverse the partner commission.
--     Any amount that cannot be recovered from the partner wallet is stored
--     as partner debt and recovered from future partner commissions.
--   * Partner dashboard displays code, rates, usage, completed sales, spend,
--     earnings and outstanding debt.
--
-- Existing users, listings, wallets and transactions are preserved.
-- Re-runnable migration.
-- =====================================================================

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.profiles') IS NULL
     OR to_regclass('public.wallets') IS NULL
     OR to_regclass('public.wallet_ledger') IS NULL
     OR to_regclass('public.marketplace_orders') IS NULL
     OR to_regclass('public.marketplace_promo_codes') IS NULL
     OR to_regclass('public.marketplace_promo_activations') IS NULL
     OR to_regclass('public.marketplace_promo_redemptions') IS NULL
     OR to_regclass('public.marketplace_disputes') IS NULL
     OR to_regclass('public.marketplace_chats') IS NULL
     OR to_regclass('public.marketplace_messages') IS NULL
     OR to_regclass('public.platform_commissions') IS NULL THEN
    RAISE EXCEPTION 'KLB marketplace prerequisites are missing. Run the existing marketplace, promo and trust/safety migrations first.';
  END IF;
  IF to_regprocedure('public.is_admin()') IS NULL
     OR to_regprocedure('public.is_staff()') IS NULL THEN
    RAISE EXCEPTION 'KLB admin/staff permission functions are missing. Run klb-account-staff-telegram.sql and marketplace-trust-safety.sql first.';
  END IF;
END;
$preflight$;

-- Partner membership is deliberately separate from profiles.role:
-- a partner can also be a buyer or seller without changing those permissions.
CREATE TABLE IF NOT EXISTS public.marketplace_partners (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  partner_type text NOT NULL DEFAULT 'creator'
    CHECK (partner_type IN ('youtube','streamer','blogger','influencer','creator','other')),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','inactive')),
  outstanding_debt numeric(14,2) NOT NULL DEFAULT 0 CHECK (outstanding_debt >= 0),
  assigned_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.marketplace_promo_codes
  ADD COLUMN IF NOT EXISTS promo_kind text NOT NULL DEFAULT 'standard',
  ADD COLUMN IF NOT EXISTS promo_name text,
  ADD COLUMN IF NOT EXISTS partner_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS partner_commission_percent numeric(5,2) NOT NULL DEFAULT 0;

-- A referral promo must retain its owner while the code exists; deleting the Auth user is
-- blocked rather than nulling partner_user_id and violating the referral-code invariant.
ALTER TABLE public.marketplace_promo_codes
  DROP CONSTRAINT IF EXISTS marketplace_promo_codes_partner_user_id_fkey;
ALTER TABLE public.marketplace_promo_codes
  ADD CONSTRAINT marketplace_promo_codes_partner_user_id_fkey
  FOREIGN KEY (partner_user_id) REFERENCES auth.users(id) ON DELETE RESTRICT;

ALTER TABLE public.marketplace_orders
  ADD COLUMN IF NOT EXISTS partner_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS partner_promo_code_id uuid REFERENCES public.marketplace_promo_codes(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS partner_promo_code text,
  ADD COLUMN IF NOT EXISTS partner_commission_percent numeric(5,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS partner_commission_amount numeric(14,2) NOT NULL DEFAULT 0;

ALTER TABLE public.marketplace_promo_redemptions
  ADD COLUMN IF NOT EXISTS partner_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS partner_commission_percent numeric(5,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS partner_commission_amount numeric(14,2) NOT NULL DEFAULT 0;

DO $constraints$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.marketplace_promo_codes'::regclass
      AND conname = 'marketplace_promo_kind_check'
  ) THEN
    ALTER TABLE public.marketplace_promo_codes
      ADD CONSTRAINT marketplace_promo_kind_check
      CHECK (promo_kind IN ('standard','referral'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.marketplace_promo_codes'::regclass
      AND conname = 'marketplace_promo_partner_rules_check'
  ) THEN
    ALTER TABLE public.marketplace_promo_codes
      ADD CONSTRAINT marketplace_promo_partner_rules_check
      CHECK (
        (promo_kind = 'standard' AND partner_user_id IS NULL AND partner_commission_percent = 0)
        OR
        (promo_kind = 'referral' AND partner_user_id IS NOT NULL
          AND discount_type = 'percent' AND discount_value > 0 AND discount_value < 100
          AND partner_commission_percent > 0 AND partner_commission_percent <= 100)
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.marketplace_orders'::regclass
      AND conname = 'marketplace_orders_partner_commission_check'
  ) THEN
    ALTER TABLE public.marketplace_orders
      ADD CONSTRAINT marketplace_orders_partner_commission_check
      CHECK (partner_commission_percent >= 0 AND partner_commission_percent <= 100
        AND partner_commission_amount >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.marketplace_promo_redemptions'::regclass
      AND conname = 'marketplace_promo_redemptions_partner_commission_check'
  ) THEN
    ALTER TABLE public.marketplace_promo_redemptions
      ADD CONSTRAINT marketplace_promo_redemptions_partner_commission_check
      CHECK (partner_commission_percent >= 0 AND partner_commission_percent <= 100
        AND partner_commission_amount >= 0);
  END IF;
END;
$constraints$;

-- Keep the newest currently-active referral code for each partner if this
-- migration is applied after a manual/pre-release test created duplicates.
WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY partner_user_id ORDER BY created_at DESC, id DESC
  ) AS rn
  FROM public.marketplace_promo_codes
  WHERE promo_kind = 'referral' AND is_active = true AND deleted_at IS NULL
)
UPDATE public.marketplace_promo_codes p
SET is_active = false
FROM ranked r
WHERE p.id = r.id AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS marketplace_one_active_referral_promo_per_partner
  ON public.marketplace_promo_codes(partner_user_id)
  WHERE promo_kind = 'referral' AND is_active = true AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS marketplace_promo_partner_idx
  ON public.marketplace_promo_codes(partner_user_id, created_at DESC)
  WHERE promo_kind = 'referral';

CREATE TABLE IF NOT EXISTS public.marketplace_partner_earnings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  buyer_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  promo_code_id uuid REFERENCES public.marketplace_promo_codes(id) ON DELETE SET NULL,
  order_id uuid NOT NULL UNIQUE REFERENCES public.marketplace_orders(id) ON DELETE RESTRICT,
  promo_code text NOT NULL,
  order_list_amount numeric(14,2) NOT NULL CHECK (order_list_amount > 0),
  customer_discount numeric(14,2) NOT NULL DEFAULT 0 CHECK (customer_discount >= 0),
  partner_commission_percent numeric(5,2) NOT NULL CHECK (partner_commission_percent > 0 AND partner_commission_percent <= 100),
  commission_amount numeric(14,2) NOT NULL CHECK (commission_amount > 0),
  credited_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (credited_amount >= 0),
  debt_recovered numeric(14,2) NOT NULL DEFAULT 0 CHECK (debt_recovered >= 0),
  status text NOT NULL DEFAULT 'credited' CHECK (status IN ('credited','reversed')),
  credited_at timestamptz NOT NULL DEFAULT now(),
  reversed_at timestamptz,
  reversal_recovered numeric(14,2) NOT NULL DEFAULT 0 CHECK (reversal_recovered >= 0),
  debt_created numeric(14,2) NOT NULL DEFAULT 0 CHECK (debt_created >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS marketplace_partner_earnings_partner_idx
  ON public.marketplace_partner_earnings(partner_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS marketplace_partner_earnings_buyer_idx
  ON public.marketplace_partner_earnings(buyer_id, created_at DESC);

ALTER TABLE public.marketplace_partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_partner_earnings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.marketplace_partners, public.marketplace_partner_earnings FROM PUBLIC, anon, authenticated;

-- Preserve the existing ledger operations and add partner reward/reversal.
DO $ledger_checks$
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
      'deposit','withdrawal_reserve','withdrawal_refund','withdrawal_paid',
      'purchase','purchase_escrow','sale','commission','adjustment',
      'dispute_refund','dispute_chargeback','promotion',
      'partner_commission','partner_commission_reversal'
    ));
END;
$ledger_checks$;

-- ---------------------------------------------------------------------
-- ADMIN: grant/revoke partner status by username.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.klb_admin_set_partner(
  p_username text,
  p_partner_type text DEFAULT 'creator',
  p_active boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_user uuid; v_profile_status text;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT id, status INTO v_user, v_profile_status
  FROM public.profiles
  WHERE lower(username) = lower(trim(p_username));
  IF v_user IS NULL THEN RAISE EXCEPTION 'Profile not found'; END IF;
  IF v_profile_status IS DISTINCT FROM 'active' AND p_active THEN
    RAISE EXCEPTION 'Partner account must be active';
  END IF;
  IF p_active THEN
    IF p_partner_type NOT IN ('youtube','streamer','blogger','influencer','creator','other') THEN
      RAISE EXCEPTION 'Invalid partner type';
    END IF;
    INSERT INTO public.marketplace_partners(user_id, partner_type, status, assigned_by, assigned_at, updated_at)
    VALUES (v_user, p_partner_type, 'active', auth.uid(), now(), now())
    ON CONFLICT (user_id) DO UPDATE
      SET partner_type = EXCLUDED.partner_type,
          status = 'active',
          assigned_by = auth.uid(),
          updated_at = now();
  ELSE
    UPDATE public.marketplace_partners
    SET status = 'inactive', updated_at = now()
    WHERE user_id = v_user;
    UPDATE public.marketplace_promo_codes
    SET is_active = false
    WHERE partner_user_id = v_user AND promo_kind = 'referral' AND is_active = true;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------
-- ADMIN: create one referral promo for an active partner.
-- Commission is a percentage of pre-discount listing subtotal.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.klb_admin_create_referral_promo(
  p_username text,
  p_promo_name text,
  p_code text,
  p_discount_percent numeric,
  p_commission_percent numeric,
  p_expires_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_partner uuid; v_row public.marketplace_promo_codes%ROWTYPE; v_code text;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  v_code := upper(trim(coalesce(p_code,'')));
  IF v_code !~ '^[A-Z0-9_-]{3,32}$' THEN RAISE EXCEPTION 'Invalid promo code'; END IF;
  IF p_discount_percent <= 0 OR p_discount_percent >= 100 THEN RAISE EXCEPTION 'Discount percentage must be between 0 and 100'; END IF;
  IF p_commission_percent <= 0 OR p_commission_percent > 100 THEN RAISE EXCEPTION 'Partner commission must be greater than 0 and at most 100'; END IF;
  IF p_expires_at IS NOT NULL AND p_expires_at <= now() THEN RAISE EXCEPTION 'Referral promo expiry must be in the future'; END IF;
  SELECT p.id INTO v_partner
  FROM public.profiles p
  JOIN public.marketplace_partners mp ON mp.user_id = p.id AND mp.status = 'active'
  WHERE lower(p.username) = lower(trim(p_username)) AND p.status = 'active';
  IF v_partner IS NULL THEN RAISE EXCEPTION 'Active partner not found'; END IF;

  UPDATE public.marketplace_promo_codes
  SET is_active = false
  WHERE partner_user_id = v_partner AND promo_kind = 'referral' AND is_active = true AND deleted_at IS NULL;

  INSERT INTO public.marketplace_promo_codes(
    code, discount_type, discount_value, max_uses, used_count,
    expires_at, is_active, created_by, promo_kind, promo_name,
    partner_user_id, partner_commission_percent
  ) VALUES (
    v_code, 'percent', p_discount_percent, NULL, 0,
    p_expires_at, true, auth.uid(), 'referral',
    coalesce(nullif(trim(p_promo_name),''), v_code), v_partner, p_commission_percent
  ) RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id, 'code', v_row.code, 'promo_name', v_row.promo_name,
    'partner_user_id', v_row.partner_user_id,
    'discount_value', v_row.discount_value,
    'partner_commission_percent', v_row.partner_commission_percent,
    'expires_at', v_row.expires_at, 'is_active', v_row.is_active
  );
END;
$function$;

-- ---------------------------------------------------------------------
-- ADMIN: edit conditions or switch a referral promo on/off.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.klb_admin_update_referral_promo(
  p_promo_id uuid,
  p_promo_name text,
  p_discount_percent numeric,
  p_commission_percent numeric,
  p_expires_at timestamptz,
  p_is_active boolean
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_promo public.marketplace_promo_codes%ROWTYPE;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO v_promo FROM public.marketplace_promo_codes WHERE id = p_promo_id FOR UPDATE;
  IF NOT FOUND OR v_promo.promo_kind <> 'referral' THEN RAISE EXCEPTION 'Referral promo not found'; END IF;
  IF p_discount_percent <= 0 OR p_discount_percent >= 100 THEN RAISE EXCEPTION 'Discount percentage must be between 0 and 100'; END IF;
  IF p_commission_percent <= 0 OR p_commission_percent > 100 THEN RAISE EXCEPTION 'Partner commission must be greater than 0 and at most 100'; END IF;
  IF p_is_active AND p_expires_at IS NOT NULL AND p_expires_at <= now() THEN RAISE EXCEPTION 'Referral promo expiry must be in the future'; END IF;
  IF p_is_active AND NOT EXISTS (
    SELECT 1 FROM public.marketplace_partners mp
    JOIN public.profiles p ON p.id = mp.user_id
    WHERE mp.user_id = v_promo.partner_user_id AND mp.status = 'active' AND p.status = 'active'
  ) THEN RAISE EXCEPTION 'Active partner not found'; END IF;

  IF p_is_active THEN
    UPDATE public.marketplace_promo_codes
    SET is_active = false
    WHERE partner_user_id = v_promo.partner_user_id AND promo_kind = 'referral'
      AND is_active = true AND deleted_at IS NULL AND id <> p_promo_id;
  END IF;

  UPDATE public.marketplace_promo_codes
  SET promo_name = coalesce(nullif(trim(p_promo_name),''), code),
      discount_type = 'percent', discount_value = p_discount_percent,
      partner_commission_percent = p_commission_percent,
      expires_at = p_expires_at,
      is_active = p_is_active,
      deleted_at = CASE WHEN p_is_active THEN NULL ELSE deleted_at END
  WHERE id = p_promo_id;
END;
$function$;

-- ---------------------------------------------------------------------
-- ADMIN: partner roster with current code and aggregate performance.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.klb_admin_partner_roster()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT coalesce(jsonb_agg(q.data ORDER BY q.assigned_at DESC), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      mp.assigned_at,
      jsonb_build_object(
        'user_id', mp.user_id,
        'username', p.username,
        'partner_type', mp.partner_type,
        'status', mp.status,
        'assigned_at', mp.assigned_at,
        'outstanding_debt', mp.outstanding_debt,
        'promo_id', promo.id,
        'promo_code', promo.code,
        'promo_name', promo.promo_name,
        'discount_percent', promo.discount_value,
        'commission_percent', promo.partner_commission_percent,
        'expires_at', promo.expires_at,
        'promo_active', coalesce(promo.is_active AND (promo.expires_at IS NULL OR promo.expires_at > now()), false),
        'code_uses', coalesce(uses.code_uses, 0),
        'completed_orders', coalesce(sales.completed_orders, 0),
        'spent_amount', coalesce(sales.spent_amount, 0),
        'earned_amount', coalesce(earn.earned_amount, 0),
        'credited_amount', coalesce(earn.credited_amount, 0)
      ) AS data
    FROM public.marketplace_partners mp
    JOIN public.profiles p ON p.id = mp.user_id
    LEFT JOIN LATERAL (
      SELECT id, code, promo_name, discount_value, partner_commission_percent, expires_at, is_active
      FROM public.marketplace_promo_codes
      WHERE partner_user_id = mp.user_id AND promo_kind = 'referral' AND deleted_at IS NULL
      ORDER BY created_at DESC LIMIT 1
    ) promo ON true
    LEFT JOIN LATERAL (
      SELECT count(*)::bigint AS code_uses
      FROM public.marketplace_promo_redemptions
      WHERE partner_user_id = mp.user_id
    ) uses ON true
    LEFT JOIN LATERAL (
      SELECT count(*)::bigint AS completed_orders,
             coalesce(sum(gross_amount),0) AS spent_amount
      FROM public.marketplace_orders
      WHERE partner_user_id = mp.user_id AND status = 'completed'
    ) sales ON true
    LEFT JOIN LATERAL (
      SELECT coalesce(sum(commission_amount),0) AS earned_amount,
             coalesce(sum(credited_amount),0) AS credited_amount
      FROM public.marketplace_partner_earnings
      WHERE partner_user_id = mp.user_id AND status = 'credited'
    ) earn ON true
  ) q;
  RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------
-- PARTNER: own dashboard only.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.klb_partner_dashboard()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_user uuid := auth.uid(); v_partner public.marketplace_partners%ROWTYPE; v_promo jsonb;
  v_uses bigint; v_completed bigint; v_buyers bigint; v_spent numeric(14,2);
  v_list_volume numeric(14,2); v_earned numeric(14,2); v_credited numeric(14,2); v_recent jsonb;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO v_partner FROM public.marketplace_partners WHERE user_id = v_user AND status = 'active';
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT jsonb_build_object(
    'id', id, 'code', code, 'promo_name', promo_name,
    'discount_percent', discount_value,
    'commission_percent', partner_commission_percent,
    'expires_at', expires_at, 'is_active', (is_active AND (expires_at IS NULL OR expires_at > now())),
    'used_count', used_count
  ) INTO v_promo
  FROM public.marketplace_promo_codes
  WHERE partner_user_id = v_user AND promo_kind = 'referral' AND deleted_at IS NULL
  ORDER BY created_at DESC LIMIT 1;

  SELECT count(*) INTO v_uses
  FROM public.marketplace_promo_redemptions WHERE partner_user_id = v_user;
  SELECT count(*), count(DISTINCT buyer_id), coalesce(sum(gross_amount),0), coalesce(sum(list_amount),0)
  INTO v_completed, v_buyers, v_spent, v_list_volume
  FROM public.marketplace_orders
  WHERE partner_user_id = v_user AND status = 'completed';
  SELECT coalesce(sum(commission_amount),0), coalesce(sum(credited_amount),0)
  INTO v_earned, v_credited
  FROM public.marketplace_partner_earnings
  WHERE partner_user_id = v_user AND status = 'credited';
  SELECT coalesce(jsonb_agg(q.data ORDER BY q.created_at DESC), '[]'::jsonb) INTO v_recent
  FROM (
    SELECT created_at,
      jsonb_build_object(
        'code', promo_code, 'order_id', order_id,
        'order_amount', order_list_amount,
        'commission_amount', commission_amount,
        'credited_amount', credited_amount, 'debt_recovered', debt_recovered,
        'status', status, 'created_at', created_at
      ) AS data
    FROM public.marketplace_partner_earnings
    WHERE partner_user_id = v_user
    ORDER BY created_at DESC LIMIT 10
  ) q;

  RETURN jsonb_build_object(
    'partner', jsonb_build_object(
      'type', v_partner.partner_type,
      'status', v_partner.status,
      'outstanding_debt', v_partner.outstanding_debt,
      'assigned_at', v_partner.assigned_at
    ),
    'promo', coalesce(v_promo, 'null'::jsonb),
    'stats', jsonb_build_object(
      'code_uses', v_uses,
      'completed_orders', v_completed,
      'buyers_count', v_buyers,
      'spent_amount', v_spent,
      'list_volume', v_list_volume,
      'earned_amount', v_earned,
      'credited_amount', v_credited,
      'outstanding_debt', v_partner.outstanding_debt
    ),
    'recent_earnings', v_recent
  );
END;
$function$;

-- ---------------------------------------------------------------------
-- Keep customer activation secure and reject a partner using their own code.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.klb_activate_marketplace_promo(p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_user uuid := auth.uid(); v_status text; v_promo public.marketplace_promo_codes%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT status INTO v_status FROM public.profiles WHERE id = v_user;
  IF v_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'Account is blocked'; END IF;
  IF p_code IS NULL OR length(trim(p_code)) < 3 OR length(trim(p_code)) > 32 THEN
    RAISE EXCEPTION 'Promo code not found or inactive';
  END IF;
  SELECT * INTO v_promo FROM public.marketplace_promo_codes
  WHERE code = upper(trim(p_code)) AND is_active = true AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Promo code not found or inactive'; END IF;
  IF v_promo.expires_at IS NOT NULL AND v_promo.expires_at <= now() THEN RAISE EXCEPTION 'Promo code expired'; END IF;
  IF v_promo.max_uses IS NOT NULL AND v_promo.used_count >= v_promo.max_uses THEN RAISE EXCEPTION 'Promo code usage limit reached'; END IF;
  IF v_promo.discount_type = 'percent' AND v_promo.discount_value >= 100 THEN RAISE EXCEPTION 'Promo percentage must be below 100'; END IF;
  IF v_promo.promo_kind = 'referral' THEN
    IF v_promo.partner_user_id = v_user THEN RAISE EXCEPTION 'You cannot use your own partner promo'; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.marketplace_partners mp
      JOIN public.profiles pp ON pp.id = mp.user_id
      WHERE mp.user_id = v_promo.partner_user_id AND mp.status = 'active' AND pp.status = 'active'
    ) THEN
      RAISE EXCEPTION 'Promo code not found or inactive';
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM public.marketplace_promo_redemptions WHERE promo_code_id = v_promo.id AND user_id = v_user) THEN
    RAISE EXCEPTION 'Promo code already used by this account';
  END IF;
  INSERT INTO public.marketplace_promo_activations(user_id, promo_code_id, activated_at)
  VALUES (v_user, v_promo.id, now())
  ON CONFLICT (user_id) DO UPDATE SET promo_code_id = EXCLUDED.promo_code_id, activated_at = now();
  RETURN jsonb_build_object(
    'code', v_promo.code, 'promo_name', v_promo.promo_name,
    'promo_kind', v_promo.promo_kind,
    'discount_type', v_promo.discount_type,
    'discount_value', v_promo.discount_value,
    'partner_commission_percent', v_promo.partner_commission_percent,
    'expires_at', v_promo.expires_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.klb_my_active_marketplace_promo()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_user uuid := auth.uid(); v_result jsonb;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT jsonb_build_object(
    'code', p.code, 'promo_name', p.promo_name, 'promo_kind', p.promo_kind,
    'discount_type', p.discount_type, 'discount_value', p.discount_value,
    'expires_at', p.expires_at, 'activated_at', a.activated_at
  ) INTO v_result
  FROM public.marketplace_promo_activations a
  JOIN public.marketplace_promo_codes p ON p.id = a.promo_code_id
  WHERE a.user_id = v_user AND p.is_active = true AND p.deleted_at IS NULL
    AND (p.expires_at IS NULL OR p.expires_at > now())
    AND (p.max_uses IS NULL OR p.used_count < p.max_uses)
    AND (p.promo_kind <> 'referral' OR (
      p.partner_user_id <> v_user AND EXISTS (
        SELECT 1 FROM public.marketplace_partners mp
        JOIN public.profiles pp ON pp.id = mp.user_id
        WHERE mp.user_id = p.partner_user_id AND mp.status = 'active' AND pp.status = 'active'
      )
    ));
  RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------
-- Checkout with referral discount snapshot. Partner reward is NOT credited
-- here; it is credited only by confirm_marketplace_order_received().
-- Commission base is the original listing subtotal before buyer discount.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_marketplace_order(
  p_listing_id uuid,
  p_quantity integer DEFAULT 1,
  p_expected_unit_price numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_buyer uuid := auth.uid();
  v_listing public.seller_listings%ROWTYPE;
  v_buyer_status text;
  v_seller_status text;
  v_subtotal numeric(14,2);
  v_discount numeric(14,2) := 0;
  v_total numeric(14,2);
  v_fee numeric(14,2);
  v_net numeric(14,2);
  v_order public.marketplace_orders%ROWTYPE;
  v_chat_id uuid;
  v_activation public.marketplace_promo_activations%ROWTYPE;
  v_promo public.marketplace_promo_codes%ROWTYPE;
  v_partner_user uuid;
  v_partner_percent numeric(5,2) := 0;
  v_partner_commission numeric(14,2) := 0;
BEGIN
  IF v_buyer IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 999 THEN RAISE EXCEPTION 'Invalid quantity'; END IF;
  SELECT status INTO v_buyer_status FROM public.profiles WHERE id = v_buyer;
  IF v_buyer_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'Account is blocked'; END IF;

  SELECT * INTO v_listing FROM public.seller_listings WHERE id = p_listing_id FOR UPDATE;
  IF NOT FOUND OR v_listing.status <> 'active' THEN RAISE EXCEPTION 'Listing unavailable'; END IF;
  IF v_listing.seller_id = v_buyer THEN RAISE EXCEPTION 'Cannot buy your own listing'; END IF;
  SELECT status INTO v_seller_status FROM public.profiles WHERE id = v_listing.seller_id;
  IF v_seller_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'Listing unavailable'; END IF;
  IF p_expected_unit_price IS NOT NULL AND p_expected_unit_price <> v_listing.price THEN
    RAISE EXCEPTION 'Listing price changed. Refresh the catalog and try again.';
  END IF;
  IF v_listing.stock < p_quantity THEN RAISE EXCEPTION 'Not enough stock'; END IF;

  v_subtotal := round(v_listing.price * p_quantity, 2);
  SELECT * INTO v_activation FROM public.marketplace_promo_activations WHERE user_id = v_buyer FOR UPDATE;
  IF FOUND THEN
    SELECT * INTO v_promo FROM public.marketplace_promo_codes WHERE id = v_activation.promo_code_id FOR UPDATE;
    IF NOT FOUND OR v_promo.is_active IS DISTINCT FROM true OR v_promo.deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'Promo code not found or inactive';
    END IF;
    IF v_promo.expires_at IS NOT NULL AND v_promo.expires_at <= now() THEN RAISE EXCEPTION 'Promo code expired'; END IF;
    IF v_promo.max_uses IS NOT NULL AND v_promo.used_count >= v_promo.max_uses THEN RAISE EXCEPTION 'Promo code usage limit reached'; END IF;
    IF EXISTS (SELECT 1 FROM public.marketplace_promo_redemptions WHERE promo_code_id = v_promo.id AND user_id = v_buyer) THEN
      RAISE EXCEPTION 'Promo code already used by this account';
    END IF;
    IF v_promo.discount_type = 'percent' THEN
      IF v_promo.discount_value >= 100 THEN RAISE EXCEPTION 'Promo percentage must be below 100'; END IF;
      v_discount := round(v_subtotal * v_promo.discount_value / 100, 2);
    ELSE
      v_discount := LEAST(v_promo.discount_value, GREATEST(v_subtotal - 0.01, 0));
    END IF;
    v_discount := LEAST(v_discount, GREATEST(v_subtotal - 0.01, 0));

    IF v_promo.promo_kind = 'referral' THEN
      IF v_promo.partner_user_id IS NULL OR v_promo.partner_user_id = v_buyer THEN
        RAISE EXCEPTION 'You cannot use your own partner promo';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.marketplace_partners mp
        JOIN public.profiles pp ON pp.id = mp.user_id
        WHERE mp.user_id = v_promo.partner_user_id AND mp.status = 'active' AND pp.status = 'active'
      ) THEN
        RAISE EXCEPTION 'Promo code not found or inactive';
      END IF;
      v_partner_user := v_promo.partner_user_id;
      v_partner_percent := v_promo.partner_commission_percent;
      v_partner_commission := round(v_subtotal * v_partner_percent / 100, 2);
    END IF;
  END IF;

  v_total := round(v_subtotal - v_discount, 2);
  IF v_total <= 0 THEN RAISE EXCEPTION 'Promo discount exceeds order total'; END IF;
  v_fee := round(v_total * 0.05, 2);
  v_net := v_total - v_fee;

  INSERT INTO public.wallets(user_id) VALUES (v_buyer) ON CONFLICT (user_id) DO NOTHING;
  UPDATE public.wallets SET available = available - v_total, escrow = escrow + v_total, updated_at = now()
  WHERE user_id = v_buyer AND available >= v_total;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;
  INSERT INTO public.wallets(user_id) VALUES (v_listing.seller_id) ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO public.marketplace_orders(
    listing_id, buyer_id, seller_id, listing_title, listing_category,
    quantity, unit_price, list_amount, promo_discount, promo_code_id, promo_code,
    gross_amount, commission_rate, commission_amount, seller_net,
    partner_user_id, partner_promo_code_id, partner_promo_code,
    partner_commission_percent, partner_commission_amount
  ) VALUES (
    v_listing.id, v_buyer, v_listing.seller_id, v_listing.title, v_listing.category,
    p_quantity, v_listing.price, v_subtotal, v_discount,
    CASE WHEN v_discount > 0 THEN v_promo.id ELSE NULL END,
    CASE WHEN v_discount > 0 THEN v_promo.code ELSE NULL END,
    v_total, 0.0500, v_fee, v_net,
    v_partner_user, CASE WHEN v_partner_user IS NOT NULL THEN v_promo.id ELSE NULL END,
    CASE WHEN v_partner_user IS NOT NULL THEN v_promo.code ELSE NULL END,
    v_partner_percent, v_partner_commission
  ) RETURNING * INTO v_order;

  IF v_discount > 0 THEN
    UPDATE public.marketplace_promo_codes SET used_count = used_count + 1 WHERE id = v_promo.id;
    INSERT INTO public.marketplace_promo_redemptions(
      promo_code_id, user_id, order_id, code_snapshot, discount_amount,
      partner_user_id, partner_commission_percent, partner_commission_amount
    ) VALUES (
      v_promo.id, v_buyer, v_order.id, v_promo.code, v_discount,
      v_partner_user, v_partner_percent, v_partner_commission
    );
    DELETE FROM public.marketplace_promo_activations WHERE user_id = v_buyer;
  END IF;

  UPDATE public.seller_listings SET stock = stock - p_quantity WHERE id = v_listing.id;
  INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
  VALUES (v_buyer, 'purchase_escrow', -v_total, v_order.id,
    CASE WHEN v_discount > 0
      THEN 'Оплата заказа с промокодом ' || v_promo.code || '; исходная сумма ' || v_subtotal::text || ' ₽'
      ELSE 'Оплата заказа удержана до подтверждения получения' END);

  INSERT INTO public.marketplace_chats(order_id, buyer_id, seller_id)
  VALUES (v_order.id, v_buyer, v_listing.seller_id) RETURNING id INTO v_chat_id;

  RETURN jsonb_build_object(
    'order_id', v_order.id, 'chat_id', v_chat_id,
    'subtotal_amount', v_subtotal, 'promo_discount', v_discount,
    'promo_code', CASE WHEN v_discount > 0 THEN v_promo.code ELSE NULL END,
    'gross_amount', v_total, 'commission_amount', v_fee, 'seller_net', v_net,
    'partner_commission_amount', v_partner_commission, 'status', v_order.status
  );
END;
$function$;

-- ---------------------------------------------------------------------
-- Release escrow and credit seller. If this order used a referral code,
-- credit partner reward once. Existing partner debt is recovered first.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_marketplace_order_received(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_order public.marketplace_orders%ROWTYPE;
  v_earning_id uuid;
  v_partner_debt numeric(14,2) := 0;
  v_debt_recovered numeric(14,2) := 0;
  v_partner_credit numeric(14,2) := 0;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO v_order FROM public.marketplace_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.buyer_id <> auth.uid() THEN RAISE EXCEPTION 'Order unavailable'; END IF;
  IF v_order.status <> 'seller_completed' THEN RAISE EXCEPTION 'Seller has not confirmed completion'; END IF;

  UPDATE public.wallets SET escrow = escrow - v_order.gross_amount, updated_at = now()
  WHERE user_id = v_order.buyer_id AND escrow >= v_order.gross_amount;
  IF NOT FOUND THEN RAISE EXCEPTION 'Escrow balance mismatch'; END IF;

  UPDATE public.wallets SET available = available + v_order.seller_net, updated_at = now()
  WHERE user_id = v_order.seller_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Seller wallet not found'; END IF;

  INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
  VALUES
    (v_order.seller_id, 'sale', v_order.gross_amount, v_order.id, 'Продажа: сумма до комиссии сервиса'),
    (v_order.seller_id, 'commission', -v_order.commission_amount, v_order.id, 'Комиссия KLB STORE — 5%');

  INSERT INTO public.platform_commissions(order_id, seller_id, gross_amount, commission_rate, commission_amount)
  VALUES (v_order.id, v_order.seller_id, v_order.gross_amount, v_order.commission_rate, v_order.commission_amount);

  UPDATE public.marketplace_orders
  SET status = 'completed', buyer_confirmed_at = now(), updated_at = now()
  WHERE id = p_order_id;

  IF v_order.partner_user_id IS NOT NULL AND v_order.partner_commission_amount > 0 THEN
    INSERT INTO public.marketplace_partner_earnings(
      partner_user_id, buyer_id, promo_code_id, order_id, promo_code,
      order_list_amount, customer_discount, partner_commission_percent,
      commission_amount, status
    ) VALUES (
      v_order.partner_user_id, v_order.buyer_id, v_order.partner_promo_code_id,
      v_order.id, coalesce(v_order.partner_promo_code, 'REFERRAL'),
      coalesce(v_order.list_amount, v_order.gross_amount + coalesce(v_order.promo_discount,0)),
      coalesce(v_order.promo_discount,0), v_order.partner_commission_percent,
      v_order.partner_commission_amount, 'credited'
    ) ON CONFLICT (order_id) DO NOTHING
    RETURNING id INTO v_earning_id;

    IF v_earning_id IS NOT NULL THEN
      INSERT INTO public.wallets(user_id) VALUES (v_order.partner_user_id) ON CONFLICT (user_id) DO NOTHING;
      SELECT outstanding_debt INTO v_partner_debt
      FROM public.marketplace_partners WHERE user_id = v_order.partner_user_id FOR UPDATE;
      v_debt_recovered := LEAST(coalesce(v_partner_debt,0), v_order.partner_commission_amount);
      v_partner_credit := v_order.partner_commission_amount - v_debt_recovered;

      IF v_debt_recovered > 0 THEN
        UPDATE public.marketplace_partners
        SET outstanding_debt = GREATEST(0, outstanding_debt - v_debt_recovered), updated_at = now()
        WHERE user_id = v_order.partner_user_id;
      END IF;
      IF v_partner_credit > 0 THEN
        UPDATE public.wallets SET available = available + v_partner_credit, updated_at = now()
        WHERE user_id = v_order.partner_user_id;
        INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
        VALUES (v_order.partner_user_id, 'partner_commission', v_partner_credit, v_order.id,
          'Партнёрская комиссия по промокоду ' || coalesce(v_order.partner_promo_code,'')
          || '; начислено ' || v_order.partner_commission_amount::text || ' ₽'
          || CASE WHEN v_debt_recovered > 0 THEN ', погашение долга ' || v_debt_recovered::text || ' ₽' ELSE '' END);
      END IF;
      UPDATE public.marketplace_partner_earnings
      SET credited_amount = v_partner_credit, debt_recovered = v_debt_recovered
      WHERE id = v_earning_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'order_id', v_order.id, 'gross_amount', v_order.gross_amount,
    'commission_amount', v_order.commission_amount, 'seller_net', v_order.seller_net,
    'partner_commission_amount', v_partner_credit, 'status', 'completed'
  );
END;
$function$;

-- ---------------------------------------------------------------------
-- Approved completed-order disputes reverse any credited partner reward.
-- Recovery is taken from available partner funds; any remainder becomes
-- outstanding debt and is offset against the partner's future commissions.
-- ---------------------------------------------------------------------
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
  v_earning public.marketplace_partner_earnings%ROWTYPE;
  v_partner_available numeric(14,2) := 0;
  v_recovery numeric(14,2) := 0;
  v_new_debt numeric(14,2) := 0;
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

      IF v_order.partner_user_id IS NOT NULL THEN
        SELECT * INTO v_earning FROM public.marketplace_partner_earnings
        WHERE order_id = v_order.id AND status = 'credited' FOR UPDATE;
        IF FOUND THEN
          INSERT INTO public.wallets(user_id) VALUES (v_order.partner_user_id) ON CONFLICT (user_id) DO NOTHING;
          SELECT available INTO v_partner_available FROM public.wallets
          WHERE user_id = v_order.partner_user_id FOR UPDATE;
          v_recovery := LEAST(coalesce(v_partner_available,0), v_earning.commission_amount);
          v_new_debt := v_earning.commission_amount - v_recovery;
          IF v_recovery > 0 THEN
            UPDATE public.wallets SET available = available - v_recovery, updated_at = now()
            WHERE user_id = v_order.partner_user_id;
            INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
            VALUES (v_order.partner_user_id, 'partner_commission_reversal', -v_recovery, v_order.id,
              'Сторнирование партнёрской комиссии по одобренному спору');
          END IF;
          IF v_new_debt > 0 THEN
            UPDATE public.marketplace_partners
            SET outstanding_debt = outstanding_debt + v_new_debt, updated_at = now()
            WHERE user_id = v_order.partner_user_id;
          END IF;
          UPDATE public.marketplace_partner_earnings
          SET status = 'reversed', reversed_at = now(), reversal_recovered = v_recovery, debt_created = v_new_debt
          WHERE id = v_earning.id;
        END IF;
      END IF;
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
      || CASE WHEN v_order.partner_user_id IS NOT NULL AND v_dispute.prior_order_status = 'completed'
        THEN ' Партнёрская комиссия по заказу сторнирована.' || CASE WHEN v_new_debt > 0 THEN ' Часть комиссии (' || v_new_debt::text || ' ₽) учтена как долг партнёра.' ELSE '' END
        ELSE '' END
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

-- RPC permissions.
REVOKE ALL ON FUNCTION public.klb_admin_set_partner(text,text,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_admin_create_referral_promo(text,text,text,numeric,numeric,timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_admin_update_referral_promo(uuid,text,numeric,numeric,timestamptz,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_admin_partner_roster() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_partner_dashboard() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_activate_marketplace_promo(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_my_active_marketplace_promo() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_marketplace_order(uuid,integer,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_marketplace_order_received(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_staff_resolve_dispute(uuid,boolean,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.klb_admin_set_partner(text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_admin_create_referral_promo(text,text,text,numeric,numeric,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_admin_update_referral_promo(uuid,text,numeric,numeric,timestamptz,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_admin_partner_roster() TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_partner_dashboard() TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_activate_marketplace_promo(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_my_active_marketplace_promo() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_order(uuid,integer,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_marketplace_order_received(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_staff_resolve_dispute(uuid,boolean,text) TO authenticated;

COMMIT;

-- Verification (all functions should be present; no user or wallet data is printed).
SELECT to_regclass('public.marketplace_partners') AS partners_table,
       to_regclass('public.marketplace_partner_earnings') AS partner_earnings_table,
       to_regprocedure('public.klb_admin_set_partner(text,text,boolean)') AS assign_partner_rpc,
       to_regprocedure('public.klb_admin_create_referral_promo(text,text,text,numeric,numeric,timestamp with time zone)') AS create_referral_promo_rpc,
       to_regprocedure('public.klb_partner_dashboard()') AS partner_dashboard_rpc;
