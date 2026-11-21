# KLB STORE — Telegram Login OIDC и уведомления

## Что изменено в этой сборке

- Вход/быстрая регистрация через ручной OIDC Authorization Code Flow с PKCE (`response_type=code`).
- Сайт всегда отправляет явный `redirect_uri`, `state` и PKCE challenge. Edge Function обменивает code на токены через Telegram с Client ID + Client Secret и проверяет подпись ID token по JWKS, issuer и audience.
- Telegram HTTP Bot API token остаётся только на сервере и используется webhook/уведомлениями продавцам.
- Вход в Telegram больше не проверяется старым способом `hash` legacy widget.

## 1. Безопасность токена

Токен Bot API был опубликован в чате. Не добавляй его в HTML, JavaScript, `supabase-config.js`, SQL или GitHub. Поскольку токен передавался в переписке, безопаснее один раз перевыпустить его ещё раз через @BotFather (`/revoke`) и использовать только новый токен в Supabase Secrets.

## 2. Настройки Telegram Login в BotFather

1. Открой @BotFather и выбери нужного бота.
2. Открой **Login Widget**.
3. Добавь Allowed URL для сайта. Для GitHub Pages это origin вида `https://USERNAME.github.io`; для собственного домена — `https://your-domain.example`. Указывай реальные origins, на которых опубликован сайт.
4. Скопируй числовой **Client ID** из раздела Login Widget.

Важно: `data-client-id` — это только числовой Client ID. Нельзя вставлять туда HTTP Bot API token вида `число:секрет`. В текущем `supabase-config.js` временно указано `9095406427` — сверь его с Client ID, который показывает BotFather, и при необходимости замени.

## 3. Настройка frontend-конфига

В `supabase-config.js` сохрани действующие `url` и `anonKey` и заполни два Telegram-поля:

```js
telegramClientId: '9095406427',       // числовой Client ID из BotFather → Login Widget
telegramBotUsername: 'KLBSTOREBOT_bot', // публичный username бота без @
  telegramRedirectUri: 'https://l1nexoffi.github.io/KLBSTORE' // должен совпадать с BotFather и TELEGRAM_REDIRECT_URI
```

В этой сборке кнопка авторизации уже встроена в окно входа. При нажатии сайт генерирует `state` и PKCE verifier, затем перенаправляет браузер на `https://oauth.telegram.org/auth` с `response_type=code`, `redirect_uri`, `scope=openid profile telegram:bot_access`, `code_challenge` и `code_challenge_method=S256`. Возврат происходит на главную страницу KLB STORE; код передаётся в Edge Function `telegram-auth`.

`Client Secret` хранится только в Supabase Edge Function Secrets (`TELEGRAM_CLIENT_SECRET`). Он используется сервером при POST на `https://oauth.telegram.org/token`; не помещай его в `supabase-config.js`, HTML, JavaScript или SQL.

`telegramBotUsername` нужен для deep-link привязки Telegram к профилю продавца (`https://t.me/BOT_USERNAME?start=...`). Это не username канала KLB Store, если канал и бот имеют разные имена.

## 4. Edge Function Secrets в Supabase

Открой Supabase Dashboard → Edge Functions → Secrets и добавь:

- `TELEGRAM_BOT_TOKEN` — новый HTTP Bot API token после `/revoke`;
- `TELEGRAM_CLIENT_ID` — числовой Client ID из BotFather → Login Widget; он должен совпадать с `telegramClientId` в `supabase-config.js`;
- `TELEGRAM_CLIENT_SECRET` — Client Secret из BotFather (только серверный секрет);
- `TELEGRAM_REDIRECT_URI` — точно `https://l1nexoffi.github.io/KLBSTORE`, без завершающего `/`; он должен совпадать с `telegramRedirectUri` в `supabase-config.js` и записью Redirect URIs в BotFather;
- `TELEGRAM_WEBHOOK_SECRET` — случайная длинная строка не короче 32 символов;
- `SITE_URL` — полный публичный URL сайта, включая путь GitHub Pages, например `https://USERNAME.github.io/klbstore/`.

Не добавляй Bot API token в `supabase-config.js` и не коммить секреты в репозиторий. Supabase Edge Functions читают secrets из окружения. Документация: https://supabase.com/docs/guides/functions/secrets

## 5. Развертывание Edge Functions

Из корня репозитория, привязанного к правильному Supabase project, выполни:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase functions deploy telegram-auth --no-verify-jwt
supabase functions deploy telegram-webhook --no-verify-jwt
supabase functions deploy telegram-order-notify
supabase functions deploy klb-profile-username
```

`telegram-auth` принимает OIDC `id_token`, проверяет его подпись через `https://oauth.telegram.org/.well-known/jwks.json` и проверяет `iss`/`aud`. Для него нужен `TELEGRAM_CLIENT_ID`; Bot API token нужен другим Telegram-функциям.

## 6. Установка webhook бота

Webhook URL:

`https://YOUR_PROJECT_REF.supabase.co/functions/v1/telegram-webhook`

Установи webhook через Telegram Bot API `setWebhook`. Используй терминал и переменные окружения, чтобы не вставлять секреты в команду, которую сохраняет история оболочки:

```bash
curl -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
  -H 'Content-Type: application/json' \
  -d "{\"url\":\"https://YOUR_PROJECT_REF.supabase.co/functions/v1/telegram-webhook\",\"secret_token\":\"${TELEGRAM_WEBHOOK_SECRET}\"}"
```

Убедись, что ответ содержит `"ok":true`.

## 7. Привязка Telegram для уведомлений продавцу

1. Войди на сайт обычным способом или через Telegram Login.
2. Открой Профиль → **Привязать Telegram**.
3. Нажми кнопку перехода к боту и затем **Start** в Telegram.
4. После успешной привязки webhook подтвердит подключение.
5. Проведи тестовую покупку. Если продавец привязал Telegram и нажал Start, ему придёт уведомление с кнопкой **Ответить в чате**.

Сам по себе Telegram Login не создаёт личный чат с ботом. Для доставки личных уведомлений продавец должен открыть бота и нажать Start.

## 8. Проверка

Проверь на тестовых аккаунтах:

1. Вход и создание аккаунта Telegram Login.
2. Вход по обычному логину и паролю для ранее созданного пользователя.
3. Смена ника и вход с новым ником.
4. Привязка Telegram из профиля и подтверждение через `/start`.
5. Тестовая покупка и получение продавцом Telegram-сообщения с корректной ссылкой на чат.

Если кнопка Telegram не появляется, проверь, что `telegramClientId` — числовой Client ID из BotFather. Если popup не завершается, проверь Allowed URLs в Login Widget. Если Telegram Login проходит, но продавцу не приходят сообщения, проверь `TELEGRAM_BOT_TOKEN`, webhook и то, что продавец нажал Start.

## Важно о готовности

Файлы фронтенда и Edge Function подготовлены. Реальное подключение к BotFather/Supabase невозможно завершить одним ZIP: нужно вручную сохранить secrets, разрешить сайт в BotFather, развернуть Edge Functions и настроить webhook в собственном проекте.
