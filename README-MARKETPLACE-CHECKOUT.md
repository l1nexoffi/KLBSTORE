# KLB STORE — balance checkout, escrow and order chats

This update adds a wallet-funded marketplace workflow to the existing KLB STORE Supabase project.

## Install order

1. Back up the Supabase project before applying a database migration.
2. Keep the currently installed auth, wallet, seller and permissions migrations. Do **not** delete or rerun the previous SQL files.
3. In Supabase SQL Editor, run `marketplace-escrow-chat.sql` as the project owner / `postgres` role.
4. Upload the contents of `klb_full/` to the website repository root, replacing the matching current files.
5. Hard-refresh the storefront (`Ctrl+F5`). The new frontend requires the migration first because it reads `wallets.escrow`.

## Purchase lifecycle

1. A buyer with a signed-in account clicks **Купить**.
2. The storefront checks the available wallet balance and calls `create_marketplace_order`.
3. In a single database transaction, the listing and buyer wallet are locked, the displayed unit price is checked against the live server price, the available balance is debited, the same amount is put into `wallets.escrow`, stock is decremented, an order is created, and a private chat is created for the buyer and seller.
4. The seller opens **Чаты** and confirms the product / key / account / subscription / service has been delivered or performed.
5. The buyer sees the updated order state in the chat and confirms receipt.
6. `confirm_marketplace_order_received` releases escrow and credits the seller with 95% of the gross order amount. The other 5% is recorded as a service commission in `platform_commissions` and as a negative `commission` entry in the seller's `wallet_ledger`.

The buyer's purchase is charged at checkout; the seller is not paid until the buyer confirms. The commission is deducted from the seller's amount, not added to the buyer's checkout amount.

## Security boundaries

- Marketplace orders and chats are created only by server-side RPC functions.
- Buyers and sellers can read only chats where they are participants; they can send messages only as themselves and only to their own order chats.
- Buyers cannot directly set the seller-completed or completed order status.
- Seller payout, escrow release, stock reservation and commission recording are performed together in a database transaction.
- Inventory cannot become negative; the final sale moves the listing to paused status.
- Wallet and ledger rows remain protected by the existing RLS policies. The frontend never writes wallet balances directly.

## Manual smoke test

Use two separate test accounts and a low-priced test listing:

1. As seller, publish an approved listing with stock 1.
2. As buyer, ensure the wallet has enough available balance and press **Купить**.
3. Confirm the buyer's available balance decreased, escrow increased, the listing left the active catalog, and both accounts see the same chat.
4. Send one message from each account and verify it appears in the other account's chat.
5. As seller, press **Подтвердить выполнение заказа**.
6. As buyer, press the category-specific receipt confirmation in the chat.
7. Verify the order is completed, buyer escrow is reduced, seller available balance increased by 95%, and the two ledger rows (`sale` and `commission`) sum to that net credit.

For example, on a 1,000 ₽ order: 50 ₽ is the service commission and 950 ₽ is credited to the seller after buyer confirmation.

## Current limitation before real-money operation

This version does not yet include a buyer dispute workflow, automatic refund / cancellation, seller delivery deadlines, or an administrator resolution screen for orders stuck in escrow. Until those policies and screens are added and tested, an order left unconfirmed remains in escrow and must not be treated as an automatically refundable or automatically paid transaction. Test with small balances before real sales.


## Trust, safety, reviews and disputes add-on

After `marketplace-escrow-chat.sql`, run `marketplace-trust-safety.sql` once in Supabase SQL Editor as the project owner / postgres role. This add-on creates public profile reviews, account reports, order disputes and private evidence storage; enables admin read access to dispute chat transcripts; adds admin financial statistics for 7- and 30-day periods; and records refunds / seller chargebacks.

### Account reports

From a participant profile in chat, a user can report the other participant, add a description and optionally upload a screenshot (PNG/JPG/WEBP, max 5 MB). Evidence is stored in a private Storage bucket and only admins can create signed links to read it. The admin may block the account, remove seller trading privileges (seller role is revoked and active listings are paused), or mark the report as no violation.

### Reviews and public profiles

A buyer can leave one 1–5 star review after a completed order. Public profiles show the user's description, completed purchase/sale counts and seller reviews. A user edits their own description in My Profile.

### Disputes and refunds

A buyer may open one dispute for an order while it is paid, seller-completed, or completed. Evidence is optional. The order is frozen as disputed until an admin reviews the buyer/seller chat transcript. If the dispute is approved before payout, funds are returned from escrow. If the seller had already received payout, the buyer receives the gross order amount and the seller is debited the full gross amount (not the 95% net); the 5% commission already recorded by KLB STORE is retained. Seller available balance can therefore become negative and represents debt to the marketplace. Existing checkout and withdrawal RPCs still require enough positive available balance. If the dispute is rejected, the order returns to its prior state, no refund is made, and a decision message is written to the chat.

### Admin financial summary

The admin overview displays retained commission income and gross confirmed order turnover for the last 7 and 30 days. Refunded disputes are excluded from confirmed turnover; a commission already retained after a completed-order dispute remains in commission income.

### Smoke tests

Use two ordinary test accounts and a low-priced listing. Check: profile view and bio edit; account report with a screenshot; one completed sale and buyer review; dispute before payout; dispute after payout; both approve and reject outcomes; admin financial totals. For the post-payout example, a 100 ₽ order credits 95 ₽ to the seller; if an approved dispute follows while the 95 ₽ remains available, a 100 ₽ chargeback leaves the seller at -5 ₽ and refunds 100 ₽ to the buyer.
