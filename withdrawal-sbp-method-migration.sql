-- KLB STORE: modern withdrawal selector + SBP method
-- Additive migration. Keeps existing withdrawal requests and wallet balances intact.

begin;

-- Replace the original two-method checks with three supported methods.
do $$
declare c record;
begin
  for c in
    select conname
    from pg_constraint
    where conrelid = 'public.withdrawal_requests'::regclass
      and contype = 'c'
      and (
        pg_get_constraintdef(oid) ilike '%bank_phone%'
        or pg_get_constraintdef(oid) ilike '%usdt_trc20%'
      )
  loop
    execute format('alter table public.withdrawal_requests drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.withdrawal_requests
  add constraint withdrawal_requests_method_allowed_check
  check (method in ('bank_phone','sbp_phone','usdt_trc20'));

alter table public.withdrawal_requests
  add constraint withdrawal_requests_payment_details_check
  check (
    (method in ('bank_phone','sbp_phone')
      and bank_name is not null and phone is not null and crypto_address is null)
    or
    (method='usdt_trc20'
      and crypto_address is not null and bank_name is null and phone is null)
  );

-- Atomically reserve funds and create the withdrawal request.
create or replace function public.create_withdrawal_request(
  p_method text,
  p_amount numeric,
  p_bank text default null,
  p_phone text default null,
  p_address text default null
)
returns public.withdrawal_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.withdrawal_requests;
  w public.wallets;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_amount is null or p_amount < 500 then
    raise exception 'Minimum withdrawal is 500';
  end if;

  if p_method not in ('bank_phone','sbp_phone','usdt_trc20') then
    raise exception 'Unsupported method';
  end if;

  if p_method in ('bank_phone','sbp_phone') and
     (coalesce(trim(p_bank),'')='' or coalesce(trim(p_phone),'')='') then
    raise exception 'Bank and phone required';
  end if;

  if p_method='usdt_trc20' and
     (coalesce(trim(p_address),'')='' or p_address !~ '^T[1-9A-HJ-NP-Za-km-z]{33}$') then
    raise exception 'Invalid TRC20 address';
  end if;

  insert into public.wallets(user_id)
  values(auth.uid())
  on conflict(user_id) do nothing;

  update public.wallets
  set available=available-p_amount,
      reserved=reserved+p_amount,
      updated_at=now()
  where user_id=auth.uid()
    and available>=p_amount
  returning * into w;

  if not found then
    raise exception 'Insufficient balance';
  end if;

  insert into public.withdrawal_requests(
    user_id,method,bank_name,phone,crypto_address,amount
  ) values (
    auth.uid(),p_method,
    case when p_method='usdt_trc20' then null else trim(p_bank) end,
    case when p_method='usdt_trc20' then null else trim(p_phone) end,
    case when p_method='usdt_trc20' then trim(p_address) else null end,
    p_amount
  ) returning * into r;

  insert into public.wallet_ledger(user_id,operation,amount,reference_id,note)
  values(auth.uid(),'withdrawal_reserve',-p_amount,r.id,
    case p_method
      when 'sbp_phone' then 'Funds reserved for SBP withdrawal'
      when 'usdt_trc20' then 'Funds reserved for USDT TRC20 withdrawal'
      else 'Funds reserved for bank withdrawal'
    end
  );

  return r;
end;
$$;

revoke all on function public.create_withdrawal_request(text,numeric,text,text,text) from public;
grant execute on function public.create_withdrawal_request(text,numeric,text,text,text) to authenticated;

commit;

-- Verification: method constraint includes bank_phone, sbp_phone and usdt_trc20.
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid='public.withdrawal_requests'::regclass
  and contype='c'
  and (conname='withdrawal_requests_method_allowed_check'
       or conname='withdrawal_requests_payment_details_check');
