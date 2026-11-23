Быстрая установка KLB STORE — уведомления и остатки

1. Резервная копия Supabase.
2. Выполнить KLB_STORE_notifications_inventory_fix.sql в SQL Editor.
3. Заменить файлы GitHub Pages содержимым папки klb_full. Сохранить свой supabase-config.js.
4. В Supabase Edge Functions обновить telegram-order-notify кодом из supabase/functions/telegram-order-notify/index.ts и Deploy.
5. Создать/обновить telegram-admin-notify кодом из supabase/functions/telegram-admin-notify/index.ts и Deploy.
6. Для обеих функций Verify JWT = ON. Для telegram-webhook оставить Verify JWT = OFF.
7. Проверить, что у продавца и администратора в public.klb_telegram_accounts есть telegram_chat_id или telegram_user_id.

Полная инструкция: KLB_STORE_NOTIFICATIONS_STOCK_INSTALL_RU.txt
Порядок безопасного сброса тестового баланса и отображаемой статистики: KLB_STORE_ADMIN_BALANCE_AND_STATS_GUIDE_RU.txt
