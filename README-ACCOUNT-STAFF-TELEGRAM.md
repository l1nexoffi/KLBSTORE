# KLB STORE — account, moderator and Telegram update

## Important token safety

A Telegram bot token was exposed in chat. Treat it as compromised: open **@BotFather**, select the bot, use `/revoke` to invalidate the old token, then create/store the replacement only as the Supabase Edge Function secret `TELEGRAM_BOT_TOKEN`. Do not reuse the exposed token. Never put a bot token, `service_role` key or webhook secret in `supabase-config.js`, GitHub Pages or frontend JavaScript.

## 1. Apply the database migration

This migration is additive. Run `klb-account-staff-telegram.sql` after the existing KLB auth, wallet, escrow/chat and trust/safety migrations. Do not rerun unrelated migrations just for this update.

The creator UUID is pinned in the SQL migration to `aaa71905-fc0d-4e72-9202-482141757e28`. The **Moderators** page is visible only to this account. Level 1 moderators can access Reports only; Level 2 can access Reports and Promo codes. Promo-code administration is included; applying/redeeming those codes at checkout is a separate feature and is not enabled by this migration.

## 2. Configure Telegram bot identity

After creating/rotating the bot token with @BotFather, set its public username (without `@`) in `supabase-config.js`:

```js
telegramBotUsername: 'YourNewBotUsername'
```

In @BotFather, use `/setdomain` and enter the exact public website domain (for example `store.example.com`). The Telegram Login Widget works only on a domain configured for the bot.

## 3. Configure Supabase Edge Function secrets

In Supabase Dashboard → Edge Functions → Secrets, set:

- `TELEGRAM_BOT_TOKEN` — the newly rotated bot token.
- `TELEGRAM_WEBHOOK_SECRET` — a long random secret (32+ random characters).
- `SITE_URL` — full website URL, e.g. `https://yourname.github.io/klbstore/`.

`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEYS` and `SUPABASE_SECRET_KEYS` are provided by current Supabase Edge Function runtimes. The functions also support legacy `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` variables. The shared key helper accepts either format. Never expose a secret/service-role key in frontend files.

## 4. Deploy Edge Functions

From the repository root, with Supabase CLI linked to the correct project:

```bash
supabase functions deploy telegram-auth --no-verify-jwt
supabase functions deploy telegram-webhook --no-verify-jwt
supabase functions deploy telegram-order-notify
supabase functions deploy klb-profile-username
```

`supabase/config.toml` already contains the expected JWT settings.

## 5. Set Telegram webhook

After deploying `telegram-webhook`, set the webhook URL to:

`https://YOUR_PROJECT_REF.supabase.co/functions/v1/telegram-webhook`

Use Telegram Bot API `setWebhook` with `secret_token` equal to `TELEGRAM_WEBHOOK_SECRET`. Do this in a secure terminal or secret manager. Do not paste the token or webhook secret into public issues, repository files or this chat. Example command template (fill variables from your secure environment):

```bash
curl -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
  -H 'Content-Type: application/json' \
  -d "{\"url\":\"https://YOUR_PROJECT_REF.supabase.co/functions/v1/telegram-webhook\",\"secret_token\":\"${TELEGRAM_WEBHOOK_SECRET}\"}"
```

## 6. Test Telegram linking and notifications

1. Sign in to KLB STORE.
2. Open Profile → **Привязать Telegram**.
3. Open the bot link and press Start. This step is necessary for the bot to obtain the private chat ID and send order notifications.
4. Have a second test account buy a low-value test listing.
5. Confirm the seller receives a Telegram notification with **Ответить в чате**. The link opens `?chat=<chat-id>`; if the seller is logged out, after signing in the site opens that chat.
6. Test Telegram Login Widget after the bot username and domain are configured.

## 7. Test account and moderators

- The creator account can assign Level 1/Level 2 moderators and revoke access in Admin → Moderators.
- Presence is refreshed every 30 seconds; online means a heartbeat within the last 2 minutes.
- The activity log records moderator assignments, report/dispute decisions and Level 2 promo-code actions. It does not record every ordinary page view.
- Username change updates both `profiles.username` and Supabase Auth's synthetic email; the next password login uses the new username.

## 8. Upload frontend

Replace the site files from `klb_full/` on your hosting. Preserve your actual `supabase-config.js`; do not overwrite it with `supabase-config.example.js`. Ensure your actual Supabase project URL and publishable/anon key remain in the config. Set only the public bot username there — never the token.

## Notes

- Telegram login and seller notifications cannot work until the Edge Functions are deployed and secrets/webhook are configured.
- Telegram seller notifications require that the seller has linked Telegram and pressed Start with the bot.
- The admin-only moderator roster is scoped to the creator UUID in the migration.
- Promo-code creation/enable/disable is ready for Level 2, but checkout redemption is not part of this update.
