-- =====================================================================
-- KLB STORE: HIERARCHICAL CATALOG + SELLER PROMOTIONS
-- Run AFTER marketplace-escrow-chat.sql and marketplace-trust-safety.sql.
-- Safe to re-run. Existing listings, users, wallets and order history are kept.
-- =====================================================================

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.seller_listings') IS NULL
     OR to_regclass('public.profiles') IS NULL
     OR to_regclass('public.wallets') IS NULL
     OR to_regclass('public.wallet_ledger') IS NULL
     OR to_regclass('public.marketplace_reviews') IS NULL THEN
    RAISE EXCEPTION 'KLB prerequisites missing. Run the seller, wallet, escrow and trust/safety migrations first.';
  END IF;
END;
$preflight$;

-- Root category and its subcategory. Keep the old category column because the
-- order flow uses it to describe the kind of digital item being delivered.
ALTER TABLE public.seller_listings
  ADD COLUMN IF NOT EXISTS catalog_category text NOT NULL DEFAULT 'other',
  ADD COLUMN IF NOT EXISTS catalog_subcategory text NOT NULL DEFAULT 'other';

-- Backfill old listing types into the new subcategory field without guessing
-- the game's / service's root category.
UPDATE public.seller_listings
SET catalog_subcategory = CASE category
  WHEN 'accounts' THEN 'accounts'
  WHEN 'keys' THEN 'keys'
  WHEN 'subscriptions' THEN 'subscriptions'
  WHEN 'services' THEN 'services'
  WHEN 'games' THEN 'digital-goods'
  ELSE 'other'
END
WHERE catalog_subcategory = 'other';

-- Best-effort categorization of older listings from their own title/description.
-- Anything not confidently recognized stays visible under "Другое".
UPDATE public.seller_listings
SET catalog_category = CASE
  WHEN lower(coalesce(title,'') || ' ' || coalesce(description,'')) ~ '(fortnite|фортнайт|v[ -]?bucks|в[ -]?бакс|вбакс)' THEN 'fortnite'
  WHEN lower(coalesce(title,'') || ' ' || coalesce(description,'')) ~ '(steam|стим)' THEN 'steam'
  WHEN lower(coalesce(title,'') || ' ' || coalesce(description,'')) ~ '(roblox|роблокс|robux|робукс)' THEN 'roblox'
  WHEN lower(coalesce(title,'') || ' ' || coalesce(description,'')) ~ '(claude|клауд)' THEN 'claude'
  WHEN lower(coalesce(title,'') || ' ' || coalesce(description,'')) ~ '(gta[ -]?6|gta vi|гта[ -]?6)' THEN 'gta6'
  WHEN lower(coalesce(title,'') || ' ' || coalesce(description,'')) ~ '(playstation|плейстейшн|ps[ -]?[45])' THEN 'playstation'
  WHEN lower(coalesce(title,'') || ' ' || coalesce(description,'')) ~ '(chatgpt|chat gpt)' THEN 'chatgpt'
  WHEN lower(coalesce(title,'') || ' ' || coalesce(description,'')) ~ '(telegram|телеграм)' THEN 'telegram'
  WHEN lower(coalesce(title,'') || ' ' || coalesce(description,'')) ~ '(brawl stars|бравл)' THEN 'brawl-stars'
  WHEN lower(coalesce(title,'') || ' ' || coalesce(description,'')) ~ '(tiktok|тикток)' THEN 'tiktok'
  ELSE 'other'
END
WHERE catalog_category = 'other';

CREATE INDEX IF NOT EXISTS seller_listings_catalog_category_idx
  ON public.seller_listings(catalog_category, catalog_subcategory, status, price);

-- Paid promotion history. The newest event for each listing is its current
-- promotion; older events remain as an audit trail and are not double-counted.
CREATE TABLE IF NOT EXISTS public.marketplace_listing_promotions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id uuid NOT NULL REFERENCES public.seller_listings(id) ON DELETE CASCADE,
  seller_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  catalog_category text NOT NULL,
  paid_amount numeric(14,2) NOT NULL DEFAULT 49 CHECK (paid_amount = 49),
  promoted_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS marketplace_listing_promotions_category_time_idx
  ON public.marketplace_listing_promotions(catalog_category, promoted_at DESC);
CREATE INDEX IF NOT EXISTS marketplace_listing_promotions_listing_time_idx
  ON public.marketplace_listing_promotions(listing_id, promoted_at DESC);

ALTER TABLE public.marketplace_listing_promotions ENABLE ROW LEVEL SECURITY;
-- No direct SELECT/INSERT/UPDATE policies: reads and writes go through the
-- narrowly scoped SECURITY DEFINER RPCs below.
REVOKE ALL ON public.marketplace_listing_promotions FROM PUBLIC, anon, authenticated;

-- Include promotion in the existing wallet ledger operation allow-list while
-- preserving operations added by earlier escrow/dispute migrations.
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
      'purchase', 'purchase_escrow', 'sale', 'commission', 'adjustment',
      'dispute_refund', 'dispute_chargeback', 'promotion'
    ));
END;
$ledger_checks$;

-- Sellers may change category/subcategory only by resubmitting the listing to
-- moderation, just like title, description, price or image changes.
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
    NEW.status := 'pending';
    NEW.moderation_note := '';
    RETURN NEW;
  END IF;

  NEW.seller_id := OLD.seller_id;
  NEW.moderation_note := OLD.moderation_note;

  IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status NOT IN ('pending', 'paused') THEN
    RAISE EXCEPTION 'Only moderators can publish listings';
  END IF;

  IF (NEW.title, NEW.description, NEW.category, NEW.catalog_category,
      NEW.catalog_subcategory, NEW.price, NEW.stock, NEW.image_url)
     IS DISTINCT FROM
     (OLD.title, OLD.description, OLD.category, OLD.catalog_category,
      OLD.catalog_subcategory, OLD.price, OLD.stock, OLD.image_url) THEN
    NEW.status := 'pending';
    NEW.moderation_note := '';
  ELSIF NEW.status = 'pending' AND OLD.status = 'active' THEN
    NEW.status := 'active';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

-- Return a public, already-ranked catalog. Paid promotions have a target slot:
-- first 3 days = slot 1; afterwards the target moves down one position per day.
-- A newer promotion in the same category pushes an older promotion down one
-- place immediately. The frontend fills every unoccupied slot with organic
-- listings ordered by seller reviews, then review count, then lower price.
CREATE OR REPLACE FUNCTION public.klb_get_marketplace_catalog(
  p_catalog_category text DEFAULT NULL,
  p_catalog_subcategory text DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  seller_id uuid,
  title text,
  description text,
  category text,
  catalog_category text,
  catalog_subcategory text,
  price numeric,
  stock integer,
  image_url text,
  status text,
  created_at timestamptz,
  seller text,
  seller_role text,
  seller_rating numeric,
  seller_review_count integer,
  promotion_rank integer,
  promoted_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH active_listings AS (
    SELECT l.*, p.username AS seller_username, p.role AS seller_role
    FROM public.seller_listings l
    JOIN public.profiles p ON p.id = l.seller_id
    WHERE l.status = 'active'
      AND l.stock > 0
      AND p.status = 'active'
      AND (p_catalog_category IS NULL OR l.catalog_category = p_catalog_category)
      AND (p_catalog_subcategory IS NULL OR l.catalog_subcategory = p_catalog_subcategory)
  ),
  latest_promotions AS (
    SELECT DISTINCT ON (mp.listing_id)
      mp.listing_id, mp.catalog_category, mp.promoted_at
    FROM public.marketplace_listing_promotions mp
    JOIN active_listings al
      ON al.id = mp.listing_id
     AND al.catalog_category = mp.catalog_category
    ORDER BY mp.listing_id, mp.promoted_at DESC, mp.created_at DESC
  ),
  promotion_slots AS (
    SELECT lp.listing_id, lp.promoted_at,
      (
        1
        + (SELECT count(*)::integer
           FROM latest_promotions newer
           WHERE newer.catalog_category = lp.catalog_category
             AND newer.promoted_at > lp.promoted_at)
        + ceil(greatest(0::numeric,
            extract(epoch FROM (now() - (lp.promoted_at + interval '3 days'))) / 86400.0
          ))::integer
      ) AS promotion_rank
    FROM latest_promotions lp
  ),
  rating_summary AS (
    SELECT r.seller_id,
      round(avg(r.rating)::numeric, 2) AS seller_rating,
      count(*)::integer AS seller_review_count
    FROM public.marketplace_reviews r
    GROUP BY r.seller_id
  )
  SELECT
    al.id,
    al.seller_id,
    al.title,
    al.description,
    al.category,
    al.catalog_category,
    al.catalog_subcategory,
    al.price,
    al.stock,
    al.image_url,
    al.status,
    al.created_at,
    CASE WHEN al.seller_role = 'admin' THEN 'KLB STORE' ELSE al.seller_username END AS seller,
    al.seller_role,
    coalesce(rs.seller_rating, 0)::numeric AS seller_rating,
    coalesce(rs.seller_review_count, 0)::integer AS seller_review_count,
    ps.promotion_rank,
    ps.promoted_at
  FROM active_listings al
  LEFT JOIN rating_summary rs ON rs.seller_id = al.seller_id
  LEFT JOIN promotion_slots ps ON ps.listing_id = al.id;
$function$;

REVOKE ALL ON FUNCTION public.klb_get_marketplace_catalog(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.klb_get_marketplace_catalog(text, text) TO anon, authenticated;

-- Charge exactly 49 ₽ and create the promotion event atomically.
CREATE OR REPLACE FUNCTION public.klb_promote_seller_listing(p_listing_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_role text;
  v_status text;
  v_listing public.seller_listings%ROWTYPE;
  v_promotion public.marketplace_listing_promotions%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;

  SELECT p.role, p.status INTO v_role, v_status
  FROM public.profiles p WHERE p.id = v_user;
  IF NOT FOUND OR v_status <> 'active' THEN RAISE EXCEPTION 'Account is blocked'; END IF;
  IF v_role NOT IN ('seller', 'admin') THEN RAISE EXCEPTION 'Seller account required'; END IF;

  SELECT * INTO v_listing
  FROM public.seller_listings
  WHERE id = p_listing_id
  FOR UPDATE;
  IF NOT FOUND OR v_listing.status <> 'active' OR v_listing.stock <= 0 THEN
    RAISE EXCEPTION 'Listing must be approved and active';
  END IF;
  IF v_listing.seller_id <> v_user AND v_role <> 'admin' THEN
    RAISE EXCEPTION 'You can promote only your own listing';
  END IF;
  IF coalesce(trim(v_listing.catalog_category), '') = '' THEN
    RAISE EXCEPTION 'Listing category is missing';
  END IF;

  INSERT INTO public.wallets(user_id) VALUES (v_user)
  ON CONFLICT (user_id) DO NOTHING;

  UPDATE public.wallets
  SET available = available - 49, updated_at = now()
  WHERE user_id = v_user AND available >= 49;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance for promotion'; END IF;

  INSERT INTO public.marketplace_listing_promotions(
    listing_id, seller_id, catalog_category, paid_amount, promoted_at
  ) VALUES (
    v_listing.id, v_user, v_listing.catalog_category, 49, now()
  ) RETURNING * INTO v_promotion;

  INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
  VALUES (v_user, 'promotion', -49, v_listing.id,
    'Продвижение объявления «' || left(v_listing.title, 100) || '» на 3 дня — 49 ₽');

  RETURN jsonb_build_object(
    'promotion_id', v_promotion.id,
    'listing_id', v_listing.id,
    'amount', 49,
    'promoted_at', v_promotion.promoted_at,
    'category', v_listing.catalog_category,
    'initial_rank', 1
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.klb_promote_seller_listing(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.klb_promote_seller_listing(uuid) TO authenticated;

COMMIT;

-- Verification
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'seller_listings'
  AND column_name IN ('catalog_category', 'catalog_subcategory')
ORDER BY column_name;

SELECT to_regprocedure('public.klb_get_marketplace_catalog(text,text)') AS catalog_rpc,
       to_regprocedure('public.klb_promote_seller_listing(uuid)') AS promotion_rpc,
       to_regclass('public.marketplace_listing_promotions') AS promotions_table;
