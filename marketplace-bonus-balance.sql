-- =====================================================================
-- KLB STORE — NON-WITHDRAWABLE BONUS BALANCE
-- Run AFTER the current KLB marketplace migrations, including:
-- wallet-marketplace-migration.sql, marketplace-escrow-chat.sql,
-- marketplace-promo-redemption.sql, marketplace-trust-safety.sql,
-- marketplace-referral-partners.sql, and the current category/promotion SQL.
--
-- Admins can grant bonus funds to users. Bonuses can pay for marketplace
-- purchases but cannot be withdrawn. Checkout consumes bonus funds first.
-- Disputes refund each payment source back to its original balance bucket.
-- Existing balances and orders are preserved (old orders are marked as
-- paid entirely from the ordinary balance).
-- =====================================================================

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('public.wallets') IS NULL
     OR to_regclass('public.wallet_ledger') IS NULL
     OR to_regclass('public.marketplace_orders') IS NULL
     OR to_regclass('public.marketplace_promo_activations') IS NULL
     OR to_regclass('public.marketplace_partners') IS NULL
     OR to_regclass('public.marketplace_partner_earnings') IS NULL
     OR to_regclass('public.marketplace_disputes') IS NULL
     OR to_regclass('public.marketplace_chats') IS NULL
     OR to_regclass('public.marketplace_messages') IS NULL THEN
    RAISE EXCEPTION 'KLB marketplace prerequisite tables are missing. Apply the current marketplace, promo, trust-safety and partner migrations first.';
  END IF;
  IF to_regprocedure('public.is_admin()') IS NULL
     OR to_regprocedure('public.is_staff()') IS NULL THEN
    RAISE EXCEPTION 'KLB admin/staff permission functions are missing.';
  END IF;
END;
$preflight$;

-- Separate, non-withdrawable bonus bucket. Existing ordinary funds are untouched.
ALTER TABLE public.wallets
  ADD COLUMN IF NOT EXISTS bonus_available numeric(14,2) NOT NULL DEFAULT 0;

DO $wallet_bonus_check$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.wallets'::regclass
      AND conname = 'wallets_bonus_available_nonnegative_check'
  ) THEN
    ALTER TABLE public.wallets
      ADD CONSTRAINT wallets_bonus_available_nonnegative_check CHECK (bonus_available >= 0);
  END IF;
END;
$wallet_bonus_check$;

-- Snapshot which part of each paid order came from ordinary versus bonus funds.
ALTER TABLE public.marketplace_orders
  ADD COLUMN IF NOT EXISTS regular_paid_amount numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS bonus_paid_amount numeric(14,2) NOT NULL DEFAULT 0;

UPDATE public.marketplace_orders
SET regular_paid_amount = gross_amount,
    bonus_paid_amount = 0
WHERE regular_paid_amount = 0 AND bonus_paid_amount = 0;

DO $order_bonus_check$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.marketplace_orders'::regclass
      AND conname = 'marketplace_orders_payment_buckets_check'
  ) THEN
    ALTER TABLE public.marketplace_orders
      ADD CONSTRAINT marketplace_orders_payment_buckets_check
      CHECK (regular_paid_amount >= 0 AND bonus_paid_amount >= 0
        AND round(regular_paid_amount + bonus_paid_amount, 2) = gross_amount);
  END IF;
END;
$order_bonus_check$;

-- Optional actor field makes manual awards traceable in wallet history.
ALTER TABLE public.wallet_ledger
  ADD COLUMN IF NOT EXISTS actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

-- Preserve all existing KLB operation names and add the three bonus operations.
DO $ledger_operation_check$
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
      'deposit', 'withdrawal_reserve', 'withdrawal_refund', 'withdrawal_paid',
      'purchase', 'purchase_escrow', 'sale', 'commission', 'adjustment',
      'promotion', 'partner_commission', 'partner_commission_reversal',
      'dispute_chargeback', 'dispute_refund',
      'bonus_grant', 'bonus_purchase', 'bonus_refund'
    ));
END;
$ledger_operation_check$;

-- Admin-only award. This credits ONLY bonus_available, never the withdrawable balance.
CREATE OR REPLACE FUNCTION public.klb_admin_grant_bonus(
  p_user_id uuid,
  p_amount numeric,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_username text;
  v_status text;
  v_amount numeric(14,2);
  v_new_bonus numeric(14,2);
  v_ref uuid := gen_random_uuid();
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'User not found'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount > 1000000 THEN
    RAISE EXCEPTION 'Bonus amount must be greater than 0 and at most 1000000';
  END IF;
  IF length(trim(coalesce(p_reason, ''))) < 3 OR length(trim(p_reason)) > 250 THEN
    RAISE EXCEPTION 'Bonus reason must contain 3 to 250 characters';
  END IF;

  SELECT username, status INTO v_username, v_status
  FROM public.profiles WHERE id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'User not found'; END IF;
  IF v_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'Cannot grant bonus to blocked account'; END IF;

  v_amount := round(p_amount, 2);
  IF v_amount <= 0 THEN RAISE EXCEPTION 'Bonus amount must be greater than 0 and at most 1000000'; END IF;
  INSERT INTO public.wallets(user_id) VALUES (p_user_id) ON CONFLICT (user_id) DO NOTHING;
  UPDATE public.wallets
  SET bonus_available = bonus_available + v_amount,
      updated_at = now()
  WHERE user_id = p_user_id
  RETURNING bonus_available INTO v_new_bonus;

  INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note, actor_id)
  VALUES (
    p_user_id, 'bonus_grant', v_amount, v_ref,
    'Бонус начислен администратором ' || coalesce((SELECT username FROM public.profiles WHERE id = auth.uid()), 'admin')
      || '. Причина: ' || trim(p_reason),
    auth.uid()
  );

  RETURN jsonb_build_object(
    'user_id', p_user_id,
    'username', v_username,
    'amount', v_amount,
    'bonus_available', v_new_bonus,
    'reference_id', v_ref
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.klb_admin_grant_bonus(uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.klb_admin_grant_bonus(uuid,numeric,text) TO authenticated;

-- Rebuild checkout with the currently-installed referral-promo logic plus bonus-first payment.
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
  v_wallet public.wallets%ROWTYPE;
  v_bonus_to_use numeric(14,2) := 0;
  v_regular_to_use numeric(14,2) := 0;
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
  SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_buyer FOR UPDATE;
  -- Bonus funds are non-withdrawable and are consumed first. The remainder
  -- is taken from the ordinary wallet balance. Withdrawals only debit available.
  v_bonus_to_use := LEAST(coalesce(v_wallet.bonus_available, 0), v_total);
  v_regular_to_use := v_total - v_bonus_to_use;
  IF coalesce(v_wallet.available, 0) < v_regular_to_use THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;
  UPDATE public.wallets
  SET available = available - v_regular_to_use,
      bonus_available = bonus_available - v_bonus_to_use,
      escrow = escrow + v_total,
      updated_at = now()
  WHERE user_id = v_buyer;
  INSERT INTO public.wallets(user_id) VALUES (v_listing.seller_id) ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO public.marketplace_orders(
    listing_id, buyer_id, seller_id, listing_title, listing_category,
    quantity, unit_price, list_amount, promo_discount, promo_code_id, promo_code,
    gross_amount, commission_rate, commission_amount, seller_net,
    regular_paid_amount, bonus_paid_amount,
    partner_user_id, partner_promo_code_id, partner_promo_code,
    partner_commission_percent, partner_commission_amount
  ) VALUES (
    v_listing.id, v_buyer, v_listing.seller_id, v_listing.title, v_listing.category,
    p_quantity, v_listing.price, v_subtotal, v_discount,
    CASE WHEN v_discount > 0 THEN v_promo.id ELSE NULL END,
    CASE WHEN v_discount > 0 THEN v_promo.code ELSE NULL END,
    v_total, 0.0500, v_fee, v_net,
    v_regular_to_use, v_bonus_to_use,
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
  IF v_regular_to_use > 0 THEN
    INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
    VALUES (v_buyer, 'purchase_escrow', -v_regular_to_use, v_order.id,
      'Обычные средства удержаны в эскроу' || CASE WHEN v_discount > 0 THEN '; промокод ' || v_promo.code ELSE '' END);
  END IF;
  IF v_bonus_to_use > 0 THEN
    INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
    VALUES (v_buyer, 'bonus_purchase', -v_bonus_to_use, v_order.id,
      'Бонусные средства использованы для покупки; нельзя вывести');
  END IF;

  INSERT INTO public.marketplace_chats(order_id, buyer_id, seller_id)
  VALUES (v_order.id, v_buyer, v_listing.seller_id) RETURNING id INTO v_chat_id;

  RETURN jsonb_build_object(
    'order_id', v_order.id, 'chat_id', v_chat_id,
    'subtotal_amount', v_subtotal, 'promo_discount', v_discount,
    'promo_code', CASE WHEN v_discount > 0 THEN v_promo.code ELSE NULL END,
    'gross_amount', v_total, 'commission_amount', v_fee, 'seller_net', v_net,
    'regular_paid_amount', v_regular_to_use, 'bonus_paid_amount', v_bonus_to_use,
    'partner_commission_amount', v_partner_commission, 'status', v_order.status
  );
END;
$function$;

-- Restore split payment sources on approved disputes without changing seller chargeback/referral reversal rules.
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
      UPDATE public.wallets
      SET available = available + coalesce(v_order.regular_paid_amount, v_order.gross_amount),
          bonus_available = bonus_available + coalesce(v_order.bonus_paid_amount, 0),
          updated_at = now()
      WHERE user_id = v_order.buyer_id;
      INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
      VALUES (v_order.seller_id, 'dispute_chargeback', -v_order.gross_amount, v_order.id, 'Полное списание по одобренному спору');
      IF coalesce(v_order.regular_paid_amount, v_order.gross_amount) > 0 THEN
        INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
        VALUES (v_order.buyer_id, 'dispute_refund', coalesce(v_order.regular_paid_amount, v_order.gross_amount), v_order.id,
          'Возврат обычных средств по одобренному спору');
      END IF;
      IF coalesce(v_order.bonus_paid_amount, 0) > 0 THEN
        INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
        VALUES (v_order.buyer_id, 'bonus_refund', v_order.bonus_paid_amount, v_order.id,
          'Возврат бонусных средств по одобренному спору; средства остаются невыводимыми');
      END IF;

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
        available = available + coalesce(v_order.regular_paid_amount, v_order.gross_amount),
        bonus_available = bonus_available + coalesce(v_order.bonus_paid_amount, 0),
        updated_at = now()
      WHERE user_id = v_order.buyer_id AND escrow >= v_order.gross_amount;
      IF NOT FOUND THEN RAISE EXCEPTION 'Escrow balance mismatch'; END IF;
      IF coalesce(v_order.regular_paid_amount, v_order.gross_amount) > 0 THEN
        INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
        VALUES (v_order.buyer_id, 'dispute_refund', coalesce(v_order.regular_paid_amount, v_order.gross_amount), v_order.id,
          'Возврат обычных средств из эскроу по одобренному спору');
      END IF;
      IF coalesce(v_order.bonus_paid_amount, 0) > 0 THEN
        INSERT INTO public.wallet_ledger(user_id, operation, amount, reference_id, note)
        VALUES (v_order.buyer_id, 'bonus_refund', v_order.bonus_paid_amount, v_order.id,
          'Возврат бонусных средств из эскроу по одобренному спору; средства остаются невыводимыми');
      END IF;
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

REVOKE ALL ON FUNCTION public.create_marketplace_order(uuid,integer,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_marketplace_order(uuid,integer,numeric) TO authenticated;
REVOKE ALL ON FUNCTION public.klb_staff_resolve_dispute(uuid,boolean,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.klb_staff_resolve_dispute(uuid,boolean,text) TO authenticated;

-- Authenticated users may read only their own wallet through existing RLS;
-- admins may read all wallets via the existing admin policy.
GRANT SELECT ON public.wallets TO authenticated;
GRANT SELECT ON public.wallet_ledger TO authenticated;

COMMIT;

-- Verification: all expected columns and RPC must be present.
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'wallets'
  AND column_name IN ('available', 'bonus_available', 'reserved', 'escrow')
ORDER BY column_name;

SELECT has_function_privilege('authenticated', 'public.klb_admin_grant_bonus(uuid,numeric,text)', 'EXECUTE') AS authenticated_can_call_rpc;
