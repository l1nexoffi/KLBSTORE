# KLB STORE — GitHub Pages demo

Static demo project. Upload the contents of this folder to the repository root.

## GitHub Pages
1. Upload all files and folders to the repository root.
2. Repository Settings → Pages → Deploy from branch → `main` → `/ (root)`.
3. Public store: the repository Pages URL.
4. Demo admin: append `/admin-login.html`.

## Demo admin credentials
- Login: `Kolobok`
- Password: `kolobokad`

The demo gate is client-side only. Credentials are present in JavaScript and can be discovered by visitors; it is NOT secure and must not be used to protect real data. `sessionStorage` is used to keep the demo login session until the browser tab/session ends.

## Demo features
- Add/edit/delete listings in admin; listings start as `На проверке`.
- Publish/unpublish listings. Only `Активно` listings appear in the public catalog when local listing data exists.
- Seller application form on the store; admin can approve/reject/delete applications.
- Demo orders created from product detail button; admin can advance status or delete.
- Local demo users can be added, blocked/unblocked, or deleted.
- Demo reports can be added, marked resolved, or deleted.
- Store settings, JSON export/import, and demo data reset.
- All demo data is stored in the browser's `localStorage` and is not shared between visitors/devices.

## Hosting migration
Static files can be uploaded as-is to a static host. For real production use, implement server-side authentication, database storage, API endpoints, payment processing, and server validation. Do not rely on this client-side login or localStorage for real access control or commerce.
