# KLB STORE — Telegram Mini App: автоматический вход

## Что исправлено

Предыдущий сайт использовал Telegram OIDC только для внешнего браузера и не подключал `telegram-web-app.js`. Из-за этого запуск через Menu Button / Main Mini App не использовал Telegram `initData`, и пользователь видел лишний экран авторизации.

В этой сборке:
- В `<head>` подключён официальный `telegram-web-app.js`.
- При запуске из Telegram сайт вызывает `Telegram.WebApp.ready()` и `expand()`.
- Raw `Telegram.WebApp.initData` отправляется на сервер без доверия к `initDataUnsafe`.
- `telegram-auth` проверяет HMAC подпись initData с использованием `TELEGRAM_BOT_TOKEN` и срок `auth_date`.
- Если в WebView уже есть сессия KLB STORE, Telegram связывается с этим профилем.
- Если сессии нет, сайт входит в ранее привязанный аккаунт или создаёт новый аккаунт KLB STORE.
- Вход через OIDC для Chrome/обычного браузера сохранён.

## 1. Обнови GitHub Pages

1. Распакуй ZIP.
2. Замени файлы репозитория содержимым папки `klb_full`.
3. Сохрани свой реальный `supabase-config.js` — в архиве только пример, твой конфиг не перезаписывай.
4. Дождись публикации GitHub Pages.

## 2. Обнови Edge Function через Supabase Dashboard (CLI не нужен)

1. Открой Supabase → Edge Functions → `telegram-auth` → Code.
2. Открой файл `klb_full/TELEGRAM-MINIAPP-AUTH-INDEX.txt` (или `klb_full/supabase/functions/telegram-auth/index.ts`).
3. Скопируй его содержимое полностью.
4. Замени весь код файла `index.ts` функции `telegram-auth`.
5. Нажми Deploy.
6. В Settings функции проверь, что `Verify JWT` выключен (OFF). Mini App login вызывается до создания Supabase-сессии; функция сама проверяет подпись Telegram `initData`. Для привязки существующего аккаунта функция дополнительно проверяет Supabase JWT через `auth.getUser()`.

Код функции самодостаточный: он не требует отдельного файла `_shared/keys.ts` при вставке через Dashboard.

## 3. Secrets Supabase

Оставь следующие секреты:

- `TELEGRAM_BOT_TOKEN` — актуальный токен именно того бота, чья Mini App запускается.
- `TELEGRAM_CLIENT_ID` — числовой Client ID для OIDC в обычном браузере.
- `TELEGRAM_CLIENT_SECRET` — Client Secret для OIDC.
- `TELEGRAM_REDIRECT_URI` — точный OIDC callback, например `https://l1nexoffi.github.io/KLBSTORE`.
- `TELEGRAM_WEBHOOK_SECRET` — защита webhook `/start`, не Client Secret.
- `SITE_URL` — `https://l1nexoffi.github.io/KLBSTORE/`.

Не вставляй bot token, Client Secret или webhook secret в HTML, JavaScript или GitHub.

## 4. Настрой BotFather URL

Открой @BotFather → `/mybots` → `KLBSTOREBOT_bot`.

Задай один и тот же URL в настройках Main Mini App и Menu Button:

`https://l1nexoffi.github.io/KLBSTORE/`

Для Menu Button используй Bot Settings → Menu Button или команду `/setmenubutton`. Для профиля бота настрой Main Mini App через Bot Settings → Configure Mini App → Enable Mini App.

Не используй только `https://l1nexoffi.github.io/`: это корень GitHub Pages, а KLB STORE находится в подпапке `/KLBSTORE/`.

## 5. Как будет работать привязка аккаунта

- Если пользователь уже вошёл в KLB STORE на этом устройстве, запуск Mini App свяжет Telegram с текущим аккаунтом.
- Если Telegram ранее привязан к аккаунту KLB STORE, запуск Mini App войдёт в этот аккаунт.
- Если Telegram ещё не привязан и KLB-сессии нет, будет создан отдельный аккаунт с временным логином `tg<telegram-id>`. Пользователь сможет сменить его в профиле.
- Чтобы присоединить Telegram к старому аккаунту с логином/паролем на новом устройстве, сначала войди в старый аккаунт в этом же Mini App, затем привяжи Telegram в профиле. Это не позволяет захватывать аккаунты по известному нику.
- Если этот Telegram уже привязан к другому профилю KLB STORE, сервер отклонит привязку; он не будет автоматически менять владельца.

## 6. Проверка

1. Открой личный чат с `@KLBSTOREBOT_bot` в Telegram.
2. Нажми Menu Button или Launch App.
3. Должен открыться KLB STORE без дополнительного OIDC-окна и автоматически войти/создать аккаунт.
4. В Supabase → Edge Functions → `telegram-auth` → Logs проверь вызов.
5. Для обычного Chrome открой сайт отдельно — там по-прежнему должна работать кнопка «Войти через Telegram» через OIDC.

SQL не требуется: используется уже установленная таблица `public.klb_telegram_accounts` из Telegram setup migration.
