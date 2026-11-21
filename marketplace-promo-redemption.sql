-- =====================================================================
-- KLB STORE — CUSTOMER PROMO ACTIVATION + CHECKOUT REDEMPTION
-- Run after marketplace-escrow-chat.sql and klb-account-staff-telegram.sql.
-- Admin/moderator promo management remains unchanged.
-- One active promo per user; one redemption of each promo per account.
-- Promo discount reduces the buyer's paid amount and seller payout base;
-- the 5% marketplace commission is calculated on the discounted amount.
-- =====================================================================

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.marketplace_promo_codes') IS NULL THEN
    RAISE EXCEPTION 'marketplace_promo_codes is missing. Run klb-account-staff-telegram.sql first.';
  END IF;
  IF to_regclass('public.marketplace_orders') IS NULL
     OR to_regclass('public.marketplace_chats') IS NULL
     OR to_regclass('public.wallets') IS NULL
     OR to_regclass('public.wallet_ledger') IS NULL
     OR to_regclass('public.seller_listings') IS NULL THEN
    RAISE EXCEPTION 'Marketplace checkout tables are missing. Run marketplace-escrow-chat.sql first.';
  END IF;
END;
$preflight$;

-- Order accounting: list_amount is the catalog subtotal, gross_amount is what buyer actually pays.
ALTER TABLE public.marketplace_orders
  ADD COLUMN IF NOT EXISTS list_amount numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS promo_discount numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS promo_code_id uuid REFERENCES public.marketplace_promo_codes(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS promo_code text;

UPDATE public.marketplace_orders SET list_amount = gross_amount WHERE list_amount = 0;

-- Remove the original check tying gross_amount to list price; the new check accounts for discount.
DO $drop_old_math$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.marketplace_orders'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%gross_amount%'
      AND pg_get_constraintdef(oid) ILIKE '%unit_price%'
  LOOP
    EXECUTE format('ALTER TABLE public.marketplace_orders DROP CONSTRAINT %I', c.conname);
  END LOOP;
END;
$drop_old_math$;

DO $new_math$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.marketplace_orders'::regclass
      AND conname = 'marketplace_orders_promo_math_check'
  ) THEN
    ALTER TABLE public.marketplace_orders
      ADD CONSTRAINT marketplace_orders_promo_math_check
      CHECK (list_amount > 0 AND promo_discount >= 0 AND promo_discount < list_amount
             AND gross_amount = list_amount - promo_discount);
  END IF;
END;
$new_math$;

CREATE TABLE IF NOT EXISTS public.marketplace_promo_activations (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  promo_code_id uuid NOT NULL REFERENCES public.marketplace_promo_codes(id) ON DELETE RESTRICT,
  activated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.marketplace_promo_redemptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  promo_code_id uuid NOT NULL REFERENCES public.marketplace_promo_codes(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL UNIQUE REFERENCES public.marketplace_orders(id) ON DELETE RESTRICT,
  code_snapshot text NOT NULL,
  discount_amount numeric(14,2) NOT NULL CHECK (discount_amount > 0),
  redeemed_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (promo_code_id, user_id)
);
CREATE INDEX IF NOT EXISTS marketplace_promo_redemptions_user_idx
  ON public.marketplace_promo_redemptions(user_id, redeemed_at DESC);

ALTER TABLE public.marketplace_promo_activations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_promo_redemptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.marketplace_promo_activations, public.marketplace_promo_redemptions FROM anon, authenticated;

-- User activates a code in profile. Validation is server-side; global usage is counted only on purchase.
CREATE OR REPLACE FUNCTION public.klb_activate_marketplace_promo(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_status text;
  v_promo public.marketplace_promo_codes%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT status INTO v_status FROM public.profiles WHERE id = v_user;
  IF v_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'Account is blocked'; END IF;
  IF p_code IS NULL OR length(trim(p_code)) < 3 OR length(trim(p_code)) > 32 THEN
    RAISE EXCEPTION 'Promo code not found or inactive';
  END IF;

  SELECT * INTO v_promo
  FROM public.marketplace_promo_codes
  WHERE code = upper(trim(p_code))
    AND is_active = true AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Promo code not found or inactive'; END IF;
  IF v_promo.expires_at IS NOT NULL AND v_promo.expires_at <= now() THEN
    RAISE EXCEPTION 'Promo code expired';
  END IF;
  IF v_promo.max_uses IS NOT NULL AND v_promo.used_count >= v_promo.max_uses THEN
    RAISE EXCEPTION 'Promo code usage limit reached';
  END IF;
  IF v_promo.discount_type = 'percent' AND v_promo.discount_value >= 100 THEN
    RAISE EXCEPTION 'Promo percentage must be below 100';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.marketplace_promo_redemptions
    WHERE promo_code_id = v_promo.id AND user_id = v_user
  ) THEN RAISE EXCEPTION 'Promo code already used by this account'; END IF;

  INSERT INTO public.marketplace_promo_activations(user_id, promo_code_id, activated_at)
  VALUES (v_user, v_promo.id, now())
  ON CONFLICT (user_id) DO UPDATE
    SET promo_code_id = EXCLUDED.promo_code_id, activated_at = now();

  RETURN jsonb_build_object(
    'code', v_promo.code,
    'discount_type', v_promo.discount_type,
    'discount_value', v_promo.discount_value,
    'expires_at', v_promo.expires_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.klb_my_active_marketplace_promo()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT jsonb_build_object(
    'code', p.code,
    'discount_type', p.discount_type,
    'discount_value', p.discount_value,
    'expires_at', p.expires_at,
    'activated_at', a.activated_at
  ) INTO v_result
  FROM public.marketplace_promo_activations a
  JOIN public.marketplace_promo_codes p ON p.id = a.promo_code_id
  WHERE a.user_id = auth.uid()
    AND p.is_active = true AND p.deleted_at IS NULL
    AND (p.expires_at IS NULL OR p.expires_at > now())
    AND (p.max_uses IS NULL OR p.used_count < p.max_uses);
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.klb_deactivate_marketplace_promo()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  DELETE FROM public.marketplace_promo_activations WHERE user_id = auth.uid();
END;
$function$;

-- Checkout automatically consumes the buyer's activated code, if any.
-- All balance, stock, promo usage and redemption writes happen in this one transaction.
CREATE OR REPLACE FUNCTION public.create_marketplace_order(
  p_listing_id uuid,
  p_quantity integer DEFAULT 1,
  p_expected_unit_price numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
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
BEGIN
  IF v_buyer IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 999 THEN RAISE EXCEPTION 'Invalid quantity'; END IF;

  SELECT status INTO v_buyer_status FROM public.profiles WHERE id = v_buyer;
  IF v_buyer_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'Account is blocked'; END IF;

  SELECT * INTO v_listing
  FROM public.seller_listings
  WHERE id = p_listing_id
  FOR UPDATE;
  IF NOT FOUND OR v_listing.status <> 'active' THEN RAISE EXCEPTION 'Listing unavailable'; END IF;
  IF v_listing.seller_id = v_buyer THEN RAISE EXCEPTION 'Cannot buy your own listing'; END IF;
  SELECT status INTO v_seller_status FROM public.profiles WHERE id = v_listing.seller_id;
  IF v_seller_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'Listing unavailable'; END IF;
  IF p_expected_unit_price IS NOT NULL AND p_expected_unit_price <> v_listing.price THEN
    RAISE EXCEPTION 'Listing price changed. Refresh the catalog and try again.';
  END IF;
  IF v_listing.stock < p_quantity THEN RAISE EXCEPTION 'Not enough stock'; END IF;

  v_subtotal := round(v_listing.price * p_quantity, 2);

  SELECT * INTO v_activation
  FROM public.marketplace_promo_activations
  WHERE user_id = v_buyer
  FOR UPDATE;

  IF FOUND THEN
    SELECT * INTO v_promo
    FROM public.marketplace_promo_codes
    WHERE id = v_activation.promo_code_id
    FOR UPDATE;
    IF NOT FOUND OR v_promo.is_active IS DISTINCT FROM true OR v_promo.deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'Promo code not found or inactive';
    END IF;
    IF v_promo.expires_at IS NOT NULL AND v_promo.expires_at <= now() THEN
      RAISE EXCEPTION 'Promo code expired';
    END IF;
    IF v_promo.max_uses IS NOT NULL AND v_promo.used_count >= v_promo.max_uses THEN
      RAISE EXCEPTION 'Promo code usage limit reached';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.marketplace_promo_redemptions
      WHERE promo_code_id = v_promo.id AND user_id = v_buyer
    ) THEN RAISE EXCEPTION 'Promo code already used by this account'; END IF;

    IF v_promo.discount_type = 'percent' THEN
      IF v_promo.discount_value >= 100 THEN RAISE EXCEPTION 'Promo percentage must be below 100'; END IF;
      v_discount := round(v_subtotal * v_promo.discount_value / 100, 2);
    ELSE
      v_discount := LEAST(v_promo.discount_value, GREATEST(v_subtotal - 0.01, 0));
    END IF;
    v_discount := LEAST(v_discount, GREATEST(v_subtotal - 0.01, 0));
  END IF;

  v_total := round(v_subtotal - v_discount, 2);
  IF v_total <= 0 THEN RAISE EXCEPTION 'Promo discount exceeds order total'; END IF;
  v_fee := round(v_total * 0.05, 2);
  v_net := v_total - v_fee;

  INSERT INTO public.wallets(user_id) VALUES (v_buyer) ON CONFLICT (user_id) DO NOTHING;
  UPDATE public.wallets
  SET available = available - v_total,
      escrow = escrow + v_total,
      updated_at = now()
  WHERE user_id = v_buyer AND available >= v_total;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.wallets(user_id) VALUES (v_listing.seller_id) ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO public.marketplace_orders(
    listing_id, buyer_id, seller_id, listing_title, listing_category,
    quantity, unit_price, list_amount, promo_discount, promo_code_id, promo_code,
    gross_amount, commission_rate, commission_amount, seller_net
  ) VALUES (
    v_listing.id, v_buyer, v_listing.seller_id, v_listing.title, v_listing.category,
    p_quantity, v_listing.price, v_subtotal, v_discount,
    CASE WHEN v_discount > 0 THEN v_promo.id ELSE NULL END,
    CASE WHEN v_discount > 0 THEN v_promo.code ELSE NULL END,
    v_total, 0.0500, v_fee, v_net
  ) RETURNING * INTO v_order;

  IF v_discount > 0 THEN
    UPDATE public.marketplace_promo_codes
    SET used_count = used_count + 1
    WHERE id = v_promo.id;
    INSERT INTO public.marketplace_promo_redemptions(
      promo_code_id, user_id, order_id, code_snapshot, discount_amount
    ) VALUES (v_promo.id, v_buyer, v_order.id, v_promo.code, v_discount);
    DELETE FROM public.marketplace_promo_activations WHERE user_id = v_buyer;
  END IF;

  UPDATE public.seller_listings
  SET stock = stock - p_quantity
  WHERE id = v_listing.id;

  INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
  VALUES (v_buyer, 'purchase_escrow', -v_total, v_order.id,
          CASE WHEN v_discount > 0
            THEN 'Оплата заказа с промокодом ' || v_promo.code || '; исходная сумма ' || v_subtotal::text || ' ₽'
            ELSE 'Оплата заказа удержана до подтверждения получения' END);

  INSERT INTO public.marketplace_chats(order_id, buyer_id, seller_id)
  VALUES (v_order.id, v_buyer, v_listing.seller_id)
  RETURNING id INTO v_chat_id;

  RETURN jsonb_build_object(
    'order_id', v_order.id,
    'chat_id', v_chat_id,
    'subtotal_amount', v_subtotal,
    'promo_discount', v_discount,
    'promo_code', CASE WHEN v_discount > 0 THEN v_promo.code ELSE NULL END,
    'gross_amount', v_total,
    'commission_amount', v_fee,
    'seller_net', v_net,
    'status', v_order.status
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.klb_activate_marketplace_promo(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_my_active_marketplace_promo() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.klb_deactivate_marketplace_promo() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_marketplace_order(uuid, integer, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.klb_activate_marketplace_promo(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_my_active_marketplace_promo() TO authenticated;
GRANT EXECUTE ON FUNCTION public.klb_deactivate_marketplace_promo() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_order(uuid, integer, numeric) TO authenticated;

COMMIT;

-- Verification
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('marketplace_promo_activations', 'marketplace_promo_redemptions')
ORDER BY table_name;

SELECT p.proname AS function_name
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('klb_activate_marketplace_promo', 'klb_my_active_marketplace_promo', 'klb_deactivate_marketplace_promo', 'create_marketplace_order')
ORDER BY p.proname;
