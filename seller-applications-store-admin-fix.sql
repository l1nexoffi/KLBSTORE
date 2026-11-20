-- ============================================================
-- KLB STORE: SELLER APPLICATION + STORE LISTING FIX
-- Run in Supabase SQL Editor as postgres/project owner.
-- Safe to re-run. Does not delete or rewrite existing business data.
--
-- The uploaded KLB SQL setup defines seller_applications columns as:
-- username, description, benefits, age, telegram, status, admin_comment.
-- The patched frontend now writes/reads those actual column names.
-- ============================================================

BEGIN;

-- Fail clearly rather than applying a policy to an unexpected schema variant.
DO $schema_check$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'seller_applications' AND column_name = 'username'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'seller_applications' AND column_name = 'benefits'
  ) THEN
    RAISE EXCEPTION 'Expected seller_applications columns username and benefits were not found. The storefront patch is aligned to the KLB SQL setup supplied in this conversation; inspect the live table schema before continuing.';
  END IF;
END;
$schema_check$;

-- 1) Explicit Data API privileges; RLS remains the row-level security boundary.
GRANT USAGE ON SCHEMA public TO authenticated, anon;
GRANT SELECT, INSERT ON TABLE public.seller_applications TO authenticated;
GRANT UPDATE ON TABLE public.seller_applications TO authenticated;
GRANT SELECT ON TABLE public.seller_listings TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.seller_listings TO authenticated;

-- 2) Ensure a user can only submit an application for their own Auth account.
ALTER TABLE public.seller_applications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS klb_seller_application_insert_self ON public.seller_applications;
CREATE POLICY klb_seller_application_insert_self
ON public.seller_applications
FOR INSERT TO authenticated
WITH CHECK (user_id = (SELECT auth.uid()));

-- Users may read only their own application; active admins may read all.
DROP POLICY IF EXISTS klb_seller_application_read_self_admin ON public.seller_applications;
CREATE POLICY klb_seller_application_read_self_admin
ON public.seller_applications
FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()) OR public.is_admin());

-- Only active admins can update application status.
DROP POLICY IF EXISTS klb_seller_application_admin_update ON public.seller_applications;
CREATE POLICY klb_seller_application_admin_update
ON public.seller_applications
FOR UPDATE TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

-- 3) Keep seller approval compatible with either role default: buyer or user.
-- The earlier wallet migration hard-coded the fallback role as "user"; one of
-- the supplied KLB base schemas uses "buyer" instead. This function derives
-- the table's actual default and only changes a role on revoke if it is seller.
CREATE OR REPLACE FUNCTION public.admin_set_seller(p_user uuid, p_approved boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_default_role text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT substring(column_default FROM $$^'([^']+)'$$)
    INTO v_default_role
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'profiles'
    AND column_name = 'role';

  v_default_role := COALESCE(v_default_role, 'user');

  UPDATE public.profiles
  SET role = CASE
    WHEN p_approved THEN 'seller'
    WHEN role = 'seller' THEN v_default_role
    ELSE role
  END
  WHERE id = p_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found';
  END IF;
END;
$function$;
REVOKE ALL ON FUNCTION public.admin_set_seller(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_seller(uuid, boolean) TO authenticated;

-- 4) Keep listing table protected; allow sellers to create their own listings
--    under existing seller policy, and allow an admin to create a KLB STORE listing
--    with seller_id equal to the currently signed-in admin's UUID.
ALTER TABLE public.seller_listings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS klb_store_admin_insert_listing ON public.seller_listings;
CREATE POLICY klb_store_admin_insert_listing
ON public.seller_listings
FOR INSERT TO authenticated
WITH CHECK (
  seller_id = (SELECT auth.uid())
  AND public.is_admin()
);

-- 5) Reassert role-specific read/modify policies without granting public writes.
-- Existing seller policies are retained. Admin reads/updates/deletes are explicit.
DROP POLICY IF EXISTS klb_admin_read_all_listings ON public.seller_listings;
CREATE POLICY klb_admin_read_all_listings
ON public.seller_listings
FOR SELECT TO authenticated
USING (public.is_admin() OR seller_id = (SELECT auth.uid()) OR status = 'active');

DROP POLICY IF EXISTS klb_admin_update_listings ON public.seller_listings;
CREATE POLICY klb_admin_update_listings
ON public.seller_listings
FOR UPDATE TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS klb_admin_delete_listings ON public.seller_listings;
CREATE POLICY klb_admin_delete_listings
ON public.seller_listings
FOR DELETE TO authenticated
USING (public.is_admin());

COMMIT;

-- 5) Verify deployed seller application column names.
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'seller_applications'
ORDER BY ordinal_position;

-- 6) Verify admin listing policy and RLS state.
SELECT c.relname AS table_name, c.relrowsecurity AS rls_enabled
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('seller_applications', 'seller_listings')
ORDER BY c.relname;
