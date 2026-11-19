# KLB STORE — Supabase connection foundation

This archive is based on the user's uploaded `Suka.zip`.

## Connected project configuration
- Supabase URL: `https://hzgihkdvaswhdygnhmra.supabase.co`
- Browser key: publishable key supplied by the user (not a service-role key).

## Important status
The database was created in Supabase in the current conversation. This package adds a configuration file and a browser adapter aligned with the table/column names used by that database setup.

**The existing storefront and admin UI are not yet fully switched to this backend.** They still contain local demo data and localStorage paths. Do not treat this as a production-ready marketplace, and do not accept real payments yet.

## Files
- `supabase-config.js`: project URL and publishable key
- `backend.js`: Supabase Auth and data adapter
- `supabase-schema.sql`: original schema included in the uploaded archive; it does not match the SQL already executed in the Supabase project. Do not run it again without reviewing/migrating.

## Username login
The adapter maps usernames to synthetic Auth emails of the form:
`username@login.klbstore.invalid`
and assumes email confirmation is disabled for this username-only flow.

The manually created admin Auth user currently has a real email address. For username login to work, change its Auth email to the synthetic email for `Kolobok` (`kolobok@login.klbstore.invalid`) in Supabase Auth user settings, if the dashboard permits, with email confirmation disabled. Keep the password private. If Supabase requires email confirmation or rejects the synthetic address, use a verified email login instead; do not weaken Auth settings broadly.

## Browser script order
Before `backend.js`:
```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="supabase-config.js"></script>
<script src="backend.js"></script>
```

## Security
Never place a `service_role` or secret key in frontend files. Publishable key is only safe when database Row Level Security (RLS) is enabled and policies are correctly configured. Admin authority must be checked against the database profile, not a localStorage flag or hardcoded password.
