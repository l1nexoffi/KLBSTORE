// Copy to supabase-config.js and fill in values from Supabase Project Settings > API.
// Only the publishable/anon key belongs in the browser. NEVER expose service_role.
window.KLB_SUPABASE_CONFIG = {
  url: 'https://hzgihkdvaswhdygnhmra.supabase.co',
  anonKey: 'sb_publishable_6yKXKZXQvwlEJGlq1jx3aw_f-e0Sx4G',
  // Telegram Login OIDC Client ID from BotFather → Login Widget (numeric; never paste the bot API token here).
  telegramClientId: '9095406427',
  // Public bot username without @, used for the /start linking deep-link. Fill in from BotFather.
  telegramBotUsername: 'KLBSTOREBOT_bot'
};
