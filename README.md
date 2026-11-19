# KLB STORE — demo build

Static demo intended for GitHub Pages and static hosting.

## Deploy to GitHub Pages
1. Upload all files from this folder to the repository root (not the ZIP itself).
2. In Settings → Pages choose Deploy from branch, select `main` and `/ (root)`.
3. Open the published URL. Admin panel is at `/admin.html`.

## Hosting migration
Upload the same files to the hosting document root. No domain-specific paths are used.

## Demo limitations
- Admin edits and product listing data are stored in the browser's `localStorage` only.
- This is not a secure administrator login and does not synchronize across visitors/devices.
- Do not enter real personal, payment, password, or secret information.
- Production requires a backend, database, authentication, and payment integration.
