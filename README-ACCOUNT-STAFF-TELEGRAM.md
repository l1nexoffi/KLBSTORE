# KLB STORE — Account, Staff & Telegram update

This archive contains the storefront/admin frontend, the additive SQL migration, and four Supabase Edge Functions. The Telegram authentication endpoint now uses Telegram's current OpenID Connect Login Widget. It validates the signed ID token against Telegram JWKS and checks issuer + audience. It no longer expects the legacy widget's `{ id, auth_date, hash }` payload.

## Telegram credentials are not interchangeable

- `TELEGRAM_BOT_TOKEN` is the secret HTTP Bot API token. Store it only in Supabase Edge Function Secrets. It is used for Telegram webhook and sending notifications.
- `TELEGRAM_CLIENT_ID` is the numeric Client ID shown in BotFather → Login Widget. It is used by `telegram-auth` to verify the ID token audience.
- `telegramClientId` in the public `supabase-config.js` is the same numeric Client ID. Never put an HTTP Bot API token in this field.
- `telegramBotUsername` in the public config is the public bot username without `@`, used only to build `/start` deep links.

The token was shared in the conversation. Rotate it with @BotFather `/revoke` before using it in production, then set the replacement as `TELEGRAM_BOT_TOKEN` in Supabase Secrets. Never commit it.

## Required Supabase Edge Function Secrets

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CLIENT_ID`
- `TELEGRAM_WEBHOOK_SECRET`
- `SITE_URL`

Current Supabase provides `SUPABASE_SECRET_KEYS` and `SUPABASE_PUBLISHABLE_KEYS`; the shared key helper also accepts legacy `SUPABASE_SERVICE_ROLE_KEY` and `SUPABASE_ANON_KEY`.

## BotFather setup

Open the bot's Login Widget settings and add every site origin to Allowed URLs. Copy the numeric Client ID from there. The current frontend config uses Client ID `9095406427`, copied from the generated Telegram Login snippet you supplied. Confirm that this exactly matches the Client ID shown in BotFather. Set the actual public bot username in `telegramBotUsername`.

## Deploy

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase functions deploy telegram-auth --no-verify-jwt
supabase functions deploy telegram-webhook --no-verify-jwt
supabase functions deploy telegram-order-notify
supabase functions deploy klb-profile-username
```

Set the webhook on `https://YOUR_PROJECT_REF.supabase.co/functions/v1/telegram-webhook` using `setWebhook` with `TELEGRAM_WEBHOOK_SECRET` as `secret_token`. Use shell environment variables or a secrets manager; do not put token values in source files or command history.

## Seller Telegram linking

A seller must use Profile → Привязать Telegram, open the bot link and press Start. Telegram Login does not by itself grant the bot a private message chat. Once linked, successful purchases trigger `telegram-order-notify` and send the seller a message with an **Ответить в чате** deep link.

See `УСТАНОВКА-RU.md` for the step-by-step Russian setup guide.

## Client Secret и JS Login SDK

Текущая кнопка сайта использует `Telegram.Login.init()` / `Telegram.Login.open()` и получает подписанный `id_token`. Для этого сценария Client Secret в браузере и в Edge Function не нужен: сервер проверяет подпись JWT через Telegram JWKS и сверяет `iss`, `aud` и срок действия. Client Secret применяется в альтернативном OIDC Authorization Code Flow при обмене `code` на token. Не добавляйте Client Secret в публичные файлы сайта.


## Telegram Mini App auto-login update

This build also supports the Telegram Menu Button / Main Mini App via validated `Telegram.WebApp.initData`. Publish `supabase/functions/telegram-auth/index.ts` from this build and follow `TELEGRAM-MINIAPP-AUTOLOGIN-RU.md`. The existing OIDC flow remains for normal browsers.
