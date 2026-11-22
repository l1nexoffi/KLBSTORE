// Copy to supabase-config.js and fill in values from Supabase Project Settings > API.
// Only the publishable/anon key belongs in the browser. NEVER expose service_role or the Telegram bot token.
window.KLB_SUPABASE_CONFIG = {
  url: 'https://YOUR_PROJECT.supabase.co',
  anonKey: 'YOUR_SUPABASE_ANON_OR_PUBLISHABLE_KEY',
  telegramClientId: 'YOUR_NUMERIC_BOTFATHER_LOGIN_CLIENT_ID',
  telegramRedirectUri: 'https://l1nexoffi.github.io/KLBSTORE',
  telegramBotUsername: 'KLBSTOREBOT_bot'
};
