# KLB STORE — установка исправленных Telegram-уведомлений

## Что находится в сборке

- `klb-api.js` — отправляет `kind + record_id` для админских событий и `order_id` для покупки; обе функции получают явный Bearer access token текущей сессии.
- `supabase/functions/telegram-admin-notify/index.ts` — проверяет сессию пользователя, принадлежность события пользователю и отправляет сообщения активным администраторам с привязанным Telegram.
- `supabase/functions/telegram-order-notify/index.ts` — проверяет сессию покупателя и заказ, затем отправляет сообщение продавцу с привязанным Telegram.
- `supabase/functions/_shared/keys.ts` — безопасно получает ключи из переменных среды Supabase.
- `supabase/config.toml` — отключает только предварительную проверку JWT на Gateway для этих двух функций. Обе функции сами проверяют пользователя через `auth.getUser()`.

## Важно: кому приходят сообщения

1. Админские события (заявка на пополнение, заявка продавца, объявление, жалоба, спор) отправляются всем профилям `role=admin` и `status=active`, у которых есть `telegram_chat_id`.
2. Новая покупка отправляется Telegram продавца, а не владельцу магазина. Это соответствует текущей логике KLBSTORE-main: покупатель создаёт заказ, уведомление получает продавец.

## Секреты Supabase

В Supabase → Edge Functions → Secrets должны быть заданы:

- `TELEGRAM_BOT_TOKEN` — токен бота от BotFather.
- `SITE_URL` — полный публичный URL сайта, например `https://l1nexoffi.github.io/KLBSTORE/`.

Ключи Supabase обычно доступны Edge Functions автоматически. Код поддерживает `SUPABASE_SECRET_KEYS` / `SUPABASE_PUBLISHABLE_KEYS`, а также старые `SUPABASE_SERVICE_ROLE_KEY` / `SUPABASE_ANON_KEY`.

**Не добавляйте Bot Token, service-role key или другие секреты в GitHub и файлы сайта.** Если токен бота ранее публиковался или отправлялся в переписку, отзовите его через BotFather и задайте новый только в Supabase Secrets.

## Деплой через Supabase CLI

Из корня репозитория, после `supabase login` и `supabase link --project-ref <PROJECT_REF>`:

```bash
supabase functions deploy telegram-admin-notify --no-verify-jwt
supabase functions deploy telegram-order-notify --no-verify-jwt
```

Команды отключают только JWT-проверку на Gateway. Не удаляйте `auth.getUser()` из кода функций.

## После публикации сайта на GitHub Pages

1. Проверьте, что новая версия `klb-api.js` опубликована.
2. Убедитесь, что бот открыт администратором и продавцом, и каждый нажал Start.
3. Привяжите Telegram из профиля KLB STORE; проверьте, что `klb_telegram_accounts.telegram_chat_id` заполнен.
4. Для админских сообщений профиль должен иметь `role=admin` и `status=active`.
5. Для покупки Telegram должен быть привязан у продавца.

## Проверка

- Админская функция вызывается сайтом при создании заявки на пополнение, отметке оплаты, заявке продавца, создании/повторной модерации объявления, жалобе и споре.
- Заказная функция вызывается после успешного создания marketplace-заказа. Если сообщение не доставлено, в ответе функции будет `sent: false` и `reason`.
- В Supabase → Edge Functions → Logs смотрите POST-запросы. `OPTIONS 204` — обычный CORS preflight; важен результат POST и JSON-ответ функции.

Успешный HTTP 200 сам по себе ещё не гарантирует сообщение: смотрите `sent`, `failed` и `reason` в теле ответа/логах.
