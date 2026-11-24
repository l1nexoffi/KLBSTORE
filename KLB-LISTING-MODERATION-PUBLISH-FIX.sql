-- KLB STORE: allow approved sellers AND the store administrator to submit listings.
-- Run this AFTER wallet-marketplace-migration.sql and wallet-frontend-support.sql.
-- The guard_listing_changes trigger still forces every new listing to pending.

DROP POLICY IF EXISTS listings_seller_insert ON public.seller_listings;
CREATE POLICY listings_seller_insert
ON public.seller_listings
FOR INSERT
TO authenticated
WITH CHECK (
  seller_id = auth.uid()
  AND (
    public.is_admin()
    OR EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.role = 'seller'
        AND p.status = 'active'
    )
  )
);

-- Confirm the effective policy after execution.
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'seller_listings'
  AND policyname = 'listings_seller_insert';
