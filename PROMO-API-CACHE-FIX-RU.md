# Исправление SB.myActiveMarketplacePromo is not a function

Причина: браузер мог продолжать использовать закешированный старый `klb-api.js`, в котором отсутствовали методы API промокодов, хотя текущий файл уже содержит `activateMarketplacePromo`, `myActiveMarketplacePromo` и `deactivateMarketplacePromo`.

В `index.html` обновлены query-параметры версий `backend.js`, `klb-api.js` и `script.js`, чтобы браузер запросил новые файлы.

## Установка
1. Замените файлы сайта содержимым папки `klb_full` в архиве. Не заменяйте собственный `supabase-config.js`.
2. Дождитесь публикации GitHub Pages.
3. Откройте `https://l1nexoffi.github.io/KLBSTORE/` и выполните Ctrl+F5.
4. При необходимости откройте сайт в приватном окне.

SQL повторно запускать не нужно: эта ошибка означает отсутствие JavaScript-метода на объекте `SB`, а не ошибку SQL RPC. В текущем `klb-api.js` метод `myActiveMarketplacePromo()` присутствует и вызывает RPC `klb_my_active_marketplace_promo`.
