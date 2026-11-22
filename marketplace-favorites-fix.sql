-- KLB STORE: favorites for marketplace seller_listings
-- Safe additive migration. Does not modify or delete legacy favorites/products.

create table if not exists public.seller_listing_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  listing_id uuid not null references public.seller_listings(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, listing_id)
);

create index if not exists seller_listing_favorites_listing_idx
  on public.seller_listing_favorites(listing_id);

alter table public.seller_listing_favorites enable row level security;

grant select, insert, delete on public.seller_listing_favorites to authenticated;
revoke update on public.seller_listing_favorites from anon, authenticated;

 drop policy if exists seller_listing_favorites_select_own on public.seller_listing_favorites;
create policy seller_listing_favorites_select_own
  on public.seller_listing_favorites for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists seller_listing_favorites_insert_own on public.seller_listing_favorites;
create policy seller_listing_favorites_insert_own
  on public.seller_listing_favorites for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.seller_listings l
      where l.id = listing_id and l.status = 'active'
    )
  );

drop policy if exists seller_listing_favorites_delete_own on public.seller_listing_favorites;
create policy seller_listing_favorites_delete_own
  on public.seller_listing_favorites for delete to authenticated
  using (user_id = (select auth.uid()));

-- Helpful verification: table should exist and RLS should be enabled.
select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'seller_listing_favorites';
