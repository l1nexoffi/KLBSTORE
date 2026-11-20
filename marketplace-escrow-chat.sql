-- =====================================================================
-- KLB STORE: BALANCE PURCHASES + ESCROW + ORDER CHAT + 5% COMMISSION
-- Run once in Supabase SQL Editor as project owner / postgres.
-- Safe to re-run. Does not delete existing accounts, wallets, listings or history.
-- Requires: profiles, wallets, wallet_ledger, seller_listings and public.is_admin().
-- =====================================================================

BEGIN;

-- Fail early if this migration is being applied to the wrong project/schema.
DO $preflight$
BEGIN
  IF to_regclass('public.profiles') IS NULL
     OR to_regclass('public.wallets') IS NULL
     OR to_regclass('public.wallet_ledger') IS NULL
     OR to_regclass('public.seller_listings') IS NULL THEN
    RAISE EXCEPTION 'KLB prerequisite tables are missing. Run the existing KLB schema and wallet migrations first.';
  END IF;
  IF to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION 'public.is_admin() is missing. Install the KLB auth/admin repair first.';
  END IF;
END;
$preflight$;

-- Separate escrow from withdrawal-reserved funds. Buyer funds are moved here at checkout
-- and remain here until buyer confirms receipt / service completion.
ALTER TABLE public.wallets
  ADD COLUMN IF NOT EXISTS escrow numeric(14,2) NOT NULL DEFAULT 0;

DO $wallet_checks$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.wallets'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%escrow%'
  LOOP
    EXECUTE format('ALTER TABLE public.wallets DROP CONSTRAINT %I', c.conname);
  END LOOP;
  ALTER TABLE public.wallets
    ADD CONSTRAINT wallets_escrow_nonnegative_check CHECK (escrow >= 0);
END;
$wallet_checks$;

-- Stock must be allowed to reach zero after the final unit is sold.
DO $stock_checks$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.seller_listings'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%stock%'
      AND pg_get_constraintdef(oid) ~ '>[[:space:]]*0'
  LOOP
    EXECUTE format('ALTER TABLE public.seller_listings DROP CONSTRAINT %I', c.conname);
  END LOOP;
END;
$stock_checks$;

DO $add_stock_check$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.seller_listings'::regclass
      AND conname = 'seller_listings_stock_nonnegative_check'
  ) THEN
    ALTER TABLE public.seller_listings
      ADD CONSTRAINT seller_listings_stock_nonnegative_check CHECK (stock >= 0);
  END IF;
END;
$add_stock_check$;

-- Extend wallet history operation types for escrow and explicit service fee.
DO $ledger_checks$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
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
      'purchase', 'purchase_escrow', 'sale', 'commission', 'adjustment'
    ));
END;
$ledger_checks$;

-- A separate order table avoids changing the legacy/demo orders table, whose schema
-- belongs to the older products catalog. It snapshots the listing terms at checkout.
CREATE TABLE IF NOT EXISTS public.marketplace_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id uuid REFERENCES public.seller_listings(id) ON DELETE SET NULL,
  buyer_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  seller_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  listing_title text NOT NULL,
  listing_category text NOT NULL,
  quantity integer NOT NULL CHECK (quantity > 0),
  unit_price numeric(14,2) NOT NULL CHECK (unit_price > 0),
  gross_amount numeric(14,2) NOT NULL CHECK (gross_amount > 0),
  commission_rate numeric(5,4) NOT NULL DEFAULT 0.0500 CHECK (commission_rate = 0.0500),
  commission_amount numeric(14,2) NOT NULL CHECK (commission_amount >= 0),
  seller_net numeric(14,2) NOT NULL CHECK (seller_net >= 0),
  status text NOT NULL DEFAULT 'paid'
    CHECK (status IN ('paid', 'seller_completed', 'completed')),
  seller_completed_at timestamptz,
  buyer_confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (buyer_id <> seller_id),
  CHECK (gross_amount = unit_price * quantity),
  CHECK (seller_net = gross_amount - commission_amount)
);

CREATE INDEX IF NOT EXISTS marketplace_orders_buyer_idx
  ON public.marketplace_orders(buyer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS marketplace_orders_seller_idx
  ON public.marketplace_orders(seller_id, created_at DESC);
CREATE INDEX IF NOT EXISTS marketplace_orders_status_idx
  ON public.marketplace_orders(status);

-- A chat is created atomically with each paid order.
CREATE TABLE IF NOT EXISTS public.marketplace_chats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.marketplace_orders(id) ON DELETE CASCADE,
  buyer_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  seller_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (buyer_id <> seller_id)
);
CREATE INDEX IF NOT EXISTS marketplace_chats_buyer_idx
  ON public.marketplace_chats(buyer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS marketplace_chats_seller_idx
  ON public.marketplace_chats(seller_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.marketplace_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id uuid NOT NULL REFERENCES public.marketplace_chats(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  body text NOT NULL CHECK (length(trim(body)) BETWEEN 1 AND 4000),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS marketplace_messages_chat_idx
  ON public.marketplace_messages(chat_id, created_at);

-- Auditable service commission. The row is created only when the buyer confirms completion.
CREATE TABLE IF NOT EXISTS public.platform_commissions (
  order_id uuid PRIMARY KEY REFERENCES public.marketplace_orders(id) ON DELETE RESTRICT,
  seller_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  gross_amount numeric(14,2) NOT NULL,
  commission_rate numeric(5,4) NOT NULL DEFAULT 0.0500,
  commission_amount numeric(14,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.marketplace_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_commissions ENABLE ROW LEVEL SECURITY;

-- Participants can read their own order and chat. Only admins can inspect commission records.
DROP POLICY IF EXISTS klb_marketplace_orders_participants_read ON public.marketplace_orders;
CREATE POLICY klb_marketplace_orders_participants_read
ON public.marketplace_orders FOR SELECT TO authenticated
USING (buyer_id = (SELECT auth.uid()) OR seller_id = (SELECT auth.uid()) OR public.is_admin());

DROP POLICY IF EXISTS klb_marketplace_chats_participants_read ON public.marketplace_chats;
CREATE POLICY klb_marketplace_chats_participants_read
ON public.marketplace_chats FOR SELECT TO authenticated
USING (buyer_id = (SELECT auth.uid()) OR seller_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS klb_marketplace_messages_participants_read ON public.marketplace_messages;
CREATE POLICY klb_marketplace_messages_participants_read
ON public.marketplace_messages FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.marketplace_chats c
    WHERE c.id = chat_id
      AND (c.buyer_id = (SELECT auth.uid()) OR c.seller_id = (SELECT auth.uid()))
  )
);

DROP POLICY IF EXISTS klb_marketplace_messages_participants_insert ON public.marketplace_messages;
CREATE POLICY klb_marketplace_messages_participants_insert
ON public.marketplace_messages FOR INSERT TO authenticated
WITH CHECK (
  sender_id = (SELECT auth.uid())
  AND EXISTS (
    SELECT 1 FROM public.marketplace_chats c
    WHERE c.id = chat_id
      AND (c.buyer_id = (SELECT auth.uid()) OR c.seller_id = (SELECT auth.uid()))
  )
);

DROP POLICY IF EXISTS klb_platform_commissions_admin_read ON public.platform_commissions;
CREATE POLICY klb_platform_commissions_admin_read
ON public.platform_commissions FOR SELECT TO authenticated
USING (public.is_admin());

-- Explicit Data API privileges; RLS still controls which rows are visible or writable.
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON public.marketplace_orders, public.marketplace_chats,
  public.marketplace_messages, public.platform_commissions TO authenticated;
GRANT INSERT ON public.marketplace_messages TO authenticated;
GRANT SELECT ON public.wallets, public.wallet_ledger TO authenticated;

-- Inventory-only edits do not force an active listing back into moderation.
-- Any title/description/category/price/image change still goes back to pending.
CREATE OR REPLACE FUNCTION public.guard_listing_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(auth.role(), '') = 'service_role' OR public.is_admin() THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.status := 'pending';
    NEW.moderation_note := '';
    RETURN NEW;
  END IF;

  NEW.seller_id := OLD.seller_id;
  NEW.moderation_note := OLD.moderation_note;

  IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status NOT IN ('pending', 'paused') THEN
    RAISE EXCEPTION 'Only moderators can publish listings';
  END IF;

  IF (NEW.title, NEW.description, NEW.category, NEW.price, NEW.image_url)
     IS DISTINCT FROM (OLD.title, OLD.description, OLD.category, OLD.price, OLD.image_url) THEN
    NEW.status := 'pending';
    NEW.moderation_note := '';
  ELSIF NEW.stock = 0 THEN
    NEW.status := 'paused';
  ELSIF NEW.status = 'pending' AND OLD.status = 'active' THEN
    NEW.status := 'active';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

-- Checkout: atomically lock listing + buyer wallet, debit available balance,
-- move gross total to escrow, decrement stock, create order and buyer/seller chat.
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
  v_total numeric(14,2);
  v_fee numeric(14,2);
  v_net numeric(14,2);
  v_order public.marketplace_orders%ROWTYPE;
  v_chat_id uuid;
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

  v_total := round(v_listing.price * p_quantity, 2);
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
    quantity, unit_price, gross_amount, commission_rate, commission_amount, seller_net
  ) VALUES (
    v_listing.id, v_buyer, v_listing.seller_id, v_listing.title, v_listing.category,
    p_quantity, v_listing.price, v_total, 0.0500, v_fee, v_net
  ) RETURNING * INTO v_order;

  UPDATE public.seller_listings
  SET stock = stock - p_quantity
  WHERE id = v_listing.id;

  INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
  VALUES (v_buyer, 'purchase_escrow', -v_total, v_order.id,
          'Оплата заказа удержана до подтверждения получения');

  INSERT INTO public.marketplace_chats(order_id, buyer_id, seller_id)
  VALUES (v_order.id, v_buyer, v_listing.seller_id)
  RETURNING id INTO v_chat_id;

  RETURN jsonb_build_object(
    'order_id', v_order.id,
    'chat_id', v_chat_id,
    'gross_amount', v_total,
    'commission_amount', v_fee,
    'seller_net', v_net,
    'status', v_order.status
  );
END;
$function$;

-- Seller confirms that the product/service has been delivered/performed.
CREATE OR REPLACE FUNCTION public.seller_complete_marketplace_order(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_order public.marketplace_orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO v_order FROM public.marketplace_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.seller_id <> auth.uid() THEN RAISE EXCEPTION 'Order unavailable'; END IF;
  IF v_order.status <> 'paid' THEN RAISE EXCEPTION 'Order is not awaiting seller completion'; END IF;

  UPDATE public.marketplace_orders
  SET status = 'seller_completed', seller_completed_at = now(), updated_at = now()
  WHERE id = p_order_id;
END;
$function$;

-- Buyer confirms receipt. Escrow is released once; seller receives gross minus 5% fee.
CREATE OR REPLACE FUNCTION public.confirm_marketplace_order_received(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_order public.marketplace_orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO v_order FROM public.marketplace_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.buyer_id <> auth.uid() THEN RAISE EXCEPTION 'Order unavailable'; END IF;
  IF v_order.status <> 'seller_completed' THEN RAISE EXCEPTION 'Seller has not confirmed completion'; END IF;

  UPDATE public.wallets
  SET escrow = escrow - v_order.gross_amount, updated_at = now()
  WHERE user_id = v_order.buyer_id AND escrow >= v_order.gross_amount;
  IF NOT FOUND THEN RAISE EXCEPTION 'Escrow balance mismatch'; END IF;

  UPDATE public.wallets
  SET available = available + v_order.seller_net, updated_at = now()
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

  RETURN jsonb_build_object(
    'order_id', v_order.id,
    'gross_amount', v_order.gross_amount,
    'commission_amount', v_order.commission_amount,
    'seller_net', v_order.seller_net,
    'status', 'completed'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.create_marketplace_order(uuid, integer, numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.seller_complete_marketplace_order(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_marketplace_order_received(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_marketplace_order(uuid, integer, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.seller_complete_marketplace_order(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_marketplace_order_received(uuid) TO authenticated;

COMMIT;

-- Verification: expect 4 tables, RLS enabled, and the three RPCs to exist.
SELECT c.relname AS table_name, c.relrowsecurity AS rls_enabled
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('marketplace_orders', 'marketplace_chats', 'marketplace_messages', 'platform_commissions')
ORDER BY c.relname;

SELECT p.proname AS function_name
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('create_marketplace_order', 'seller_complete_marketplace_order', 'confirm_marketplace_order_received')
ORDER BY p.proname;
