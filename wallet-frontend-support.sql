-- KLB STORE: additions required by the connected frontend.
-- Run AFTER supabase-schema.sql and wallet-marketplace-migration.sql. Idempotent; changes nothing in those files.

-- 1) SECURITY FIX: moderation cannot be bypassed.
-- Without this trigger the policy "listings_seller_update" lets a seller set status='active' on their own listing.
create or replace function public.guard_listing_changes()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if coalesce(auth.role(),'')='service_role' or public.is_admin() then
    new.updated_at := now();
    return new;
  end if;
  if tg_op='INSERT' then
    new.status := 'pending'; new.moderation_note := '';
    return new;
  end if;
  -- UPDATE by the owner
  new.seller_id := old.seller_id;
  new.moderation_note := old.moderation_note;
  if new.status is distinct from old.status and new.status not in ('pending','paused') then
    raise exception 'Only moderators can publish listings';
  end if;
  if (new.title,new.description,new.category,new.price,new.stock,new.image_url)
     is distinct from (old.title,old.description,old.category,old.price,old.stock,old.image_url) then
    new.status := 'pending';           -- any content change (also of a rejected/paused listing) goes to moderation
    new.moderation_note := '';
  elsif new.status='pending' and old.status='active' then
    new.status := 'active';            -- a seller cannot "re-submit" an active listing without changes
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists guard_listing_changes_trigger on public.seller_listings;
create trigger guard_listing_changes_trigger before insert or update on public.seller_listings
for each row execute function public.guard_listing_changes();

-- 2) Blocked sellers cannot create listings.
drop policy if exists listings_seller_insert on public.seller_listings;
create policy listings_seller_insert on public.seller_listings for insert
  with check (seller_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='seller' and p.status='active'));

-- 3) User confirms "I have paid": pending -> checking (the admin still confirms the money manually).
create or replace function public.mark_deposit_checking(p_request uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  update public.deposit_requests set status='checking' where id=p_request and user_id=auth.uid() and status='pending';
  if not found then raise exception 'Request unavailable'; end if;
end $$;
revoke all on function public.mark_deposit_checking(uuid) from public;
grant execute on function public.mark_deposit_checking(uuid) to authenticated;

-- 4) Admin blocks/unblocks a user; blocking also pauses the user's active listings.
create or replace function public.admin_set_user_blocked(p_user uuid,p_blocked boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  if p_user=auth.uid() then raise exception 'Cannot block yourself'; end if;
  update public.profiles set status=case when p_blocked then 'blocked' else 'active' end where id=p_user;
  if not found then raise exception 'Profile not found'; end if;
  if p_blocked then update public.seller_listings set status='paused' where seller_id=p_user and status in ('active','pending'); end if;
end $$;
revoke all on function public.admin_set_user_blocked(uuid,boolean) from public;
grant execute on function public.admin_set_user_blocked(uuid,boolean) to authenticated;

-- 5) Blocked users cannot create money requests.
create or replace function public.assert_active_user() returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.profiles where id=auth.uid() and status='active') then raise exception 'Account is blocked'; end if;
end $$;
revoke all on function public.assert_active_user() from public;
create or replace function public.guard_blocked_requests() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.profiles where id=new.user_id and status='active') then raise exception 'Account is blocked'; end if;
  return new;
end $$;
drop trigger if exists guard_blocked_deposit on public.deposit_requests;
create trigger guard_blocked_deposit before insert on public.deposit_requests for each row execute function public.guard_blocked_requests();
drop trigger if exists guard_blocked_withdrawal on public.withdrawal_requests;
create trigger guard_blocked_withdrawal before insert on public.withdrawal_requests for each row execute function public.guard_blocked_requests();

-- 6) Listing images: public bucket, each seller writes only into their own folder <uid>/...
insert into storage.buckets(id,name,public) values('listing-images','listing-images',true) on conflict (id) do nothing;
drop policy if exists listing_images_public_read on storage.objects;
create policy listing_images_public_read on storage.objects for select using (bucket_id='listing-images');
drop policy if exists listing_images_owner_write on storage.objects;
create policy listing_images_owner_write on storage.objects for insert to authenticated
  with check (bucket_id='listing-images' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists listing_images_owner_delete on storage.objects;
create policy listing_images_owner_delete on storage.objects for delete to authenticated
  using (bucket_id='listing-images' and (storage.foldername(name))[1]=auth.uid()::text);
