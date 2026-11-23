-- KLB STORE: Telegram notifications + inventory quantity fix + reporting reset point
-- Run AFTER the installed KLB marketplace migrations (wallet, escrow, trust-safety,
-- categories/promotions, partner referrals and bonus balance).
-- This migration does not delete orders, wallets, listings, reviews or ledger history.

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.seller_listings') IS NULL
     OR to_regclass('public.marketplace_orders') IS NULL
     OR to_regclass('public.marketplace_reviews') IS NULL
     OR to_regclass('public.platform_commissions') IS NULL
     OR to_regclass('public.wallets') IS NULL
     OR to_regclass('public.wallet_ledger') IS NULL THEN
    RAISE EXCEPTION 'Required KLB marketplace tables are missing. Apply the existing marketplace migrations first.';
  END IF;
  IF to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION 'public.is_admin() is missing. Apply KLB account/staff migrations first.';
  END IF;
END;
$preflight$;

-- 1) Inventory: 0 means sold out, 1..30 is the permitted listing stock.
-- First remove legacy stock constraints so existing values can be normalized safely.
DO $stock_constraints$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.seller_listings'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%stock%'
  LOOP
    EXECUTE format('ALTER TABLE public.seller_listings DROP CONSTRAINT %I', c.conname);
  END LOOP;
END;
$stock_constraints$;

-- Important bug fix: stock-only changes (including checkout decrement) must NOT
-- put the listing back into moderation. Only product-content changes need review.
CREATE OR REPLACE FUNCTION public.guard_listing_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF coalesce(auth.role(), '') = 'service_role' OR public.is_admin() THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.stock < 1 OR NEW.stock > 30 THEN
      RAISE EXCEPTION 'Listing stock must be between 1 and 30';
    END IF;
    NEW.status := 'pending';
    NEW.moderation_note := '';
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  NEW.seller_id := OLD.seller_id;
  NEW.moderation_note := OLD.moderation_note;

  -- Sellers may pause/resubmit their listing, but may not self-publish it.
  IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status NOT IN ('pending', 'paused') THEN
    RAISE EXCEPTION 'Only moderators can publish listings';
  END IF;

  -- Inventory is deliberately excluded from this comparison. Sellers may restock
  -- without a new moderation cycle, and checkout may decrement stock safely.
  IF (NEW.title, NEW.description, NEW.category, NEW.catalog_category,
      NEW.catalog_subcategory, NEW.price, NEW.image_url)
     IS DISTINCT FROM
     (OLD.title, OLD.description, OLD.category, OLD.catalog_category,
      OLD.catalog_subcategory, OLD.price, OLD.image_url) THEN
    NEW.status := 'pending';
    NEW.moderation_note := '';
  ELSIF NEW.status = 'pending' AND OLD.status = 'active' THEN
    NEW.status := 'active';
  END IF;

  IF NEW.stock < 0 OR NEW.stock > 30 THEN
    RAISE EXCEPTION 'Listing stock must be between 0 and 30';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

-- Normalize any legacy values only after the replacement trigger no longer
-- treats stock changes as content edits.
UPDATE public.seller_listings
SET stock = LEAST(30, GREATEST(0, COALESCE(stock, 0)))
WHERE stock IS NULL OR stock < 0 OR stock > 30;

ALTER TABLE public.seller_listings
  ADD CONSTRAINT seller_listings_stock_0_30_check CHECK (stock BETWEEN 0 AND 30);

-- 2) Reporting reset point. Historical statistics are preserved on installation
-- (initial value = -infinity). Set stats_started_at = now() manually when you want a reset.
CREATE TABLE IF NOT EXISTS public.klb_marketplace_stats_control (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  stats_started_at timestamptz NOT NULL DEFAULT '-infinity'::timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
INSERT INTO public.klb_marketplace_stats_control(id, stats_started_at)
VALUES (true, '-infinity'::timestamptz)
ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.klb_marketplace_stats_control ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.klb_marketplace_stats_control FROM PUBLIC, anon, authenticated;

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
  v_started_at timestamptz;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'Profile not found';
  END IF;
  SELECT stats_started_at INTO v_started_at
  FROM public.klb_marketplace_stats_control WHERE id = true;
  v_started_at := coalesce(v_started_at, '-infinity'::timestamptz);

  SELECT count(*)::integer INTO v_purchases
  FROM public.marketplace_orders
  WHERE buyer_id = p_user_id AND status = 'completed'
    AND coalesce(buyer_confirmed_at, created_at) >= v_started_at;
  SELECT count(*)::integer INTO v_sales
  FROM public.marketplace_orders
  WHERE seller_id = p_user_id AND status = 'completed'
    AND coalesce(buyer_confirmed_at, created_at) >= v_started_at;
  SELECT coalesce(round(avg(rating)::numeric, 2), 0), count(*)::integer
  INTO v_rating, v_reviews
  FROM public.marketplace_reviews
  WHERE seller_id = p_user_id AND created_at >= v_started_at;

  RETURN jsonb_build_object(
    'completed_purchases', v_purchases,
    'completed_sales', v_sales,
    'average_rating', v_rating,
    'reviews_count', v_reviews,
    'stats_started_at', v_started_at
  );
END;
$function$;

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
  v_started_at timestamptz;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT stats_started_at INTO v_started_at
  FROM public.klb_marketplace_stats_control WHERE id = true;
  v_started_at := coalesce(v_started_at, '-infinity'::timestamptz);

  SELECT coalesce(sum(gross_amount), 0), count(*)::integer
  INTO v_turnover_7, v_orders_7
  FROM public.marketplace_orders
  WHERE buyer_confirmed_at >= GREATEST(now() - interval '7 days', v_started_at)
    AND status IN ('completed', 'disputed');
  SELECT coalesce(sum(gross_amount), 0), count(*)::integer
  INTO v_turnover_30, v_orders_30
  FROM public.marketplace_orders
  WHERE buyer_confirmed_at >= GREATEST(now() - interval '30 days', v_started_at)
    AND status IN ('completed', 'disputed');
  SELECT coalesce(sum(commission_amount), 0)
  INTO v_profit_7
  FROM public.platform_commissions
  WHERE created_at >= GREATEST(now() - interval '7 days', v_started_at);
  SELECT coalesce(sum(commission_amount), 0)
  INTO v_profit_30
  FROM public.platform_commissions
  WHERE created_at >= GREATEST(now() - interval '30 days', v_started_at);

  RETURN jsonb_build_object(
    'turnover_7d', v_turnover_7,
    'turnover_30d', v_turnover_30,
    'commission_7d', v_profit_7,
    'commission_30d', v_profit_30,
    'orders_7d', v_orders_7,
    'orders_30d', v_orders_30,
    'stats_started_at', v_started_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.marketplace_public_profile_stats(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.marketplace_admin_financial_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marketplace_public_profile_stats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marketplace_admin_financial_stats() TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Verification: all rows should show stock between 0 and 30.
SELECT count(*) AS listings_outside_0_30
FROM public.seller_listings
WHERE stock < 0 OR stock > 30;
SELECT stats_started_at FROM public.klb_marketplace_stats_control WHERE id = true;
