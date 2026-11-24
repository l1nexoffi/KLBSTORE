/* KLB STORE — Supabase API for wallet, seller applications, listings and admin.
   Load after backend.js. Does nothing when Supabase is not configured (the site then runs in local demo mode).
   All money operations go through SQL functions (RPC); the browser never writes balances. */
(() => {
  const B = window.KLBBackend;
  if (!B || !B.configured) return;
  const sb = B.client;

  const ERRORS = {
    'Authentication required': 'Войди в аккаунт.',
    'Invalid amount': 'Сумма должна быть от 100 до 1 000 000 ₽.',
    'Minimum withdrawal is 500': 'Минимальная сумма вывода 500 ₽.',
    'Insufficient balance': 'Недостаточно средств на балансе.',
    'Bonus amount must be greater than 0 and at most 1000000': 'Бонус должен быть больше 0 и не превышать 1 000 000 ₽.',
    'Bonus reason must contain 3 to 250 characters': 'Укажи причину начисления (от 3 до 250 символов).',
    'Cannot grant bonus to blocked account': 'Нельзя начислить бонус заблокированному аккаунту.',
    'Insufficient balance for promotion': 'Для продвижения нужно минимум 49 ₽ на доступном балансе.',
    'Seller account required': 'Продвигать объявления могут только продавцы.',
    'Listing must be approved and active': 'Продвигать можно только одобренное активное объявление с остатком товара.',
    'You can promote only your own listing': 'Можно продвигать только собственные объявления.',
    'Listing unavailable': 'Объявление больше недоступно.',
    'Listing price changed': 'Цена изменилась. Обнови каталог и попробуй ещё раз.',
    'Listing stock must be between 1 and 30': 'Количество в объявлении должно быть от 1 до 30.',
    'Listing stock must be between 0 and 30': 'Остаток должен быть от 0 до 30.',
    'Not enough stock': 'Недостаточно товара в наличии.',
    'Cannot buy your own listing': 'Нельзя купить собственное объявление.',
    'Invalid quantity': 'Некорректное количество товара.',
    'Order unavailable': 'Заказ не найден или у тебя нет к нему доступа.',
    'Order is not awaiting seller completion': 'Этот заказ уже обработан или не ожидает выполнения.',
    'Seller has not confirmed completion': 'Продавец ещё не подтвердил выполнение заказа.',
    'Escrow balance mismatch': 'Не удалось сверить удержанные средства. Обратись в поддержку.',
    'This order cannot be disputed': 'Этот заказ больше нельзя оспорить.',
    'Review is available only after a completed order': 'Оставить отзыв можно после завершения сделки.',
    'Rating must be from 1 to 5': 'Оценка должна быть от 1 до 5.',
    'Cannot report yourself': 'Нельзя отправить жалобу на самого себя.',
    'Chat participant unavailable': 'Пользователь не является участником этого чата.',
    'Profile not found': 'Профиль не найден.',
    'Username already taken': 'Этот никнейм уже занят.',
    'Username must be 3-24 characters': 'Никнейм должен содержать от 3 до 24 символов: латиница, цифры и _.',
    'Owner only': 'Управление доступно только создателю KLB STORE.',
    'Moderator only': 'Недостаточно прав модератора.',
    'Report description must contain 10 to 2000 characters': 'Описание жалобы должно содержать от 10 до 2000 символов.',
    'Dispute reason must contain 10 to 2000 characters': 'Причина спора должна содержать от 10 до 2000 символов.',

    'Invalid TRC20 address': 'Проверь адрес USDT TRC20.',
    'Bank and phone required': 'Укажи банк и номер телефона.',
    'Unsupported method': 'Неподдерживаемый способ вывода.',
    'Admin only': 'Недостаточно прав.',
    'Request unavailable': 'Заявка уже обработана или недоступна.',
    'Account is blocked': 'Аккаунт заблокирован.',
    'Only moderators can publish listings': 'Публиковать объявления может только модератор.',
    'Cannot block yourself': 'Нельзя заблокировать самого себя.',
    'Profile not found': 'Профиль не найден.',
    'Username already taken': 'Этот никнейм уже занят.',
    'Username must be 3-24 characters': 'Никнейм должен содержать от 3 до 24 символов: латиница, цифры и _.',
    'Owner only': 'Управление доступно только создателю KLB STORE.',
    'Moderator only': 'Недостаточно прав модератора.',
    'Invalid login credentials': 'Неверный логин или пароль.',
    'User already registered': 'Этот логин уже занят.',
    'Failed to fetch': 'Нет соединения с сервером.',
    'Promo code not found or inactive': 'Промокод не найден или отключён.',
    'Promo code expired': 'Срок действия промокода истёк.',
    'Promo code usage limit reached': 'Лимит активаций этого промокода исчерпан.',
    'Promo code already used by this account': 'Ты уже использовал этот промокод.',
    'No active promo code': 'Нет активированного промокода.',
    'Promo discount exceeds order total': 'Скидка промокода превышает стоимость заказа.',
    'Promo percentage must be below 100': 'Скидка в процентах должна быть меньше 100%.',
    'Promo code already active': 'Этот промокод уже активирован.',
    'Active partner not found': 'Партнёр не найден или его статус отключён.',
    'You cannot use your own partner promo': 'Нельзя активировать собственный партнёрский промокод.',
    'Invalid promo code': 'Некорректный формат промокода.',
    'Discount percentage must be between 0 and 100': 'Скидка должна быть больше 0% и меньше 100%.',
    'Partner commission must be greater than 0 and at most 100': 'Комиссия партнёра должна быть больше 0% и не превышать 100%.',
    'Invalid partner type': 'Выбран неизвестный тип партнёра.',
    'Partner account must be active': 'Нельзя назначить партнёром заблокированный аккаунт.',
    'Referral promo not found': 'Реферальный промокод не найден.'
  };
  const ruError = e => {
    const m = String((e && (e.message || e.error_description)) || e || '');
    for (const k in ERRORS) if (m.includes(k)) return ERRORS[k];
    if (/row-level security/i.test(m)) return 'Действие запрещено правилами доступа.';
    if (/Password should be at least/i.test(m)) return 'Пароль должен быть не короче 6 символов.';
    if (/duplicate key|already/i.test(m)) return 'Такая запись уже существует.';
    return m || 'Неизвестная ошибка.';
  };
  const must = ({ data, error }) => { if (error) throw error; return data; };
  const uid = async () => { const s = await B.session(); if (!s) throw new Error('Authentication required'); return s.user.id; };
  // Telegram admin notifications are best-effort: they never roll back a successful marketplace action.
  const notifyAdmins = async (kind, recordId) => {
    if (!recordId) return null;
    try {
      // Pass the current user's access token explicitly. The Edge Function performs
      // its own auth.getUser() validation; config.toml disables only gateway JWT
      // pre-validation to avoid gateway 401s with newer Supabase signing keys.
      const session = await B.session();
      if (!session?.access_token) {
        console.warn('KLB Telegram admin notification skipped: no active user session.');
        return null;
      }
      const { data, error } = await sb.functions.invoke('telegram-admin-notify', {
        body: { kind, record_id: recordId },
        headers: { Authorization: `Bearer ${session.access_token}` }
      });
      if (error) {
        console.warn('KLB Telegram admin notification failed:', error);
        return null;
      }
      if (data && Number(data.sent || 0) === 0) console.warn('KLB Telegram admin notification was not delivered:', data.reason || 'No linked admin Telegram accounts');
      return data;
    } catch (error) {
      console.warn('KLB Telegram admin notification failed:', error);
      return null;
    }
  };

  const DEP = { pending: 'Ожидает оплаты', checking: 'Проверка', approved: 'Подтверждено', rejected: 'Отклонено', expired: 'Истекла' };
  const WDR = { pending: 'Ожидает выплаты', paid: 'Выплачено', rejected: 'Отклонено, средства возвращены' };
  const LST = { pending: 'На проверке', active: 'Активно', rejected: 'Отклонено', paused: 'Приостановлено' };
  const APP = { pending: 'Новая', approved: 'Одобрена', rejected: 'Отклонено' };
  const LISTING_STATUS_TO_DB = { 'На проверке': 'pending', 'Активно': 'active', 'Отклонено': 'rejected', 'Приостановлено': 'paused' };

  const profilesMap = async ids => {
    ids = [...new Set(ids.filter(Boolean))];
    if (!ids.length) return {};
    const rows = must(await sb.from('profiles').select('id,username,role,status,created_at').in('id', ids));
    return Object.fromEntries(rows.map(r => [r.id, r]));
  };

  const api = {
    ruError, labels: { DEP, WDR, LST, APP },

    /* ---------- wallet (user) ---------- */
    async wallet() {
      const id = await uid();
      const r = must(await sb.from('wallets').select('available,bonus_available,reserved,escrow').eq('user_id', id).maybeSingle());
      return { available: Number(r?.available || 0), bonus_available: Number(r?.bonus_available || 0), reserved: Number(r?.reserved || 0), escrow: Number(r?.escrow || 0) };
    },
    async ledger() { return must(await sb.from('wallet_ledger').select('*').order('created_at', { ascending: false }).limit(100)); },
    async depositInstructions() {
      const r = must(await sb.rpc('get_deposit_instructions'));
      const row = Array.isArray(r) ? r[0] : r;
      return { bank: row?.bank || '', details: row?.card_or_details || '' };
    },
    async createDeposit(amount) {
      const row = must(await sb.rpc('create_deposit_request', { p_amount: amount }));
      void notifyAdmins('deposit_created', row?.id);
      return row;
    },
    async markDepositChecking(id) {
      must(await sb.rpc('mark_deposit_checking', { p_request: id }));
      void notifyAdmins('deposit_checking', id);
    },
    async createWithdrawal({ method, amount, bank, phone, address }) {
      return must(await sb.rpc('create_withdrawal_request', {
        p_method: method === 'usdt' ? 'usdt_trc20' : (method === 'sbp' ? 'sbp_phone' : 'bank_phone'), p_amount: amount,
        p_bank: method === 'usdt' ? null : bank, p_phone: method === 'usdt' ? null : phone, p_address: method === 'usdt' ? address : null
      }));
    },
    async myDeposits() { return must(await sb.from('deposit_requests').select('*').order('created_at', { ascending: false }).limit(50)); },
    async myWithdrawals() { return must(await sb.from('withdrawal_requests').select('*').order('created_at', { ascending: false }).limit(50)); },

    /* ---------- customer promo activation ---------- */
    async activateMarketplacePromo(code) {
      return must(await sb.rpc('klb_activate_marketplace_promo', { p_code: String(code || '').trim().toUpperCase() }));
    },
    async myActiveMarketplacePromo() {
      return must(await sb.rpc('klb_my_active_marketplace_promo'));
    },
    async deactivateMarketplacePromo() {
      must(await sb.rpc('klb_deactivate_marketplace_promo'));
    },
    async partnerDashboard() {
      return must(await sb.rpc('klb_partner_dashboard'));
    },

    /* ---------- seller applications (user) ---------- */
    async myApplication() {
      const id = await uid();
      const rows = must(await sb.from('seller_applications').select('*').eq('user_id', id).order('created_at', { ascending: false }).limit(1));
      return rows[0] || null;
    },
    async applyForSeller({ nickname, description, benefit, age, telegram }) {
      const id = await uid();
      // The deployed KLB schema uses username + benefits (plural), not nickname + benefit.
      const row = must(await sb.from('seller_applications').insert({
        user_id: id, username: nickname, description, benefits: benefit, age, telegram
      }).select().single());
      void notifyAdmins('seller_application', row.id);
      return row;
    },

    /* ---------- listings ---------- */
    async catalog(rootCategory = null, subcategory = null) {
      const rows = must(await sb.rpc('klb_get_marketplace_catalog', {
        p_catalog_category: rootCategory || null,
        p_catalog_subcategory: subcategory && subcategory !== 'all' ? subcategory : null
      }));
      return rows || [];
    },
    async promoteListing(listingId) {
      return must(await sb.rpc('klb_promote_seller_listing', { p_listing_id: listingId }));
    },
    /* ---------- favorites for marketplace seller_listings ---------- */
    async myFavoriteListingIds() {
      const userId = await uid();
      const rows = must(await sb.from('seller_listing_favorites')
        .select('listing_id').eq('user_id', userId).order('created_at', { ascending: false }));
      return rows.map(row => String(row.listing_id));
    },
    async migrateLegacyFavoriteListingIds(legacyIds = []) {
      const userId = await uid();
      const alreadySaved = new Set(await api.myFavoriteListingIds());
      const candidates = [...new Set((legacyIds || []).map(String))].filter(id => !alreadySaved.has(id));
      if (!candidates.length) return [...alreadySaved];
      // Only migrate IDs that really exist in the current seller_listings catalog.
      const validRows = must(await sb.from('seller_listings').select('id').in('id', candidates));
      const validIds = validRows.map(row => String(row.id));
      if (validIds.length) {
        must(await sb.from('seller_listing_favorites').insert(validIds.map(listing_id => ({ user_id: userId, listing_id }))));
      }
      return api.myFavoriteListingIds();
    },
    async myFavoriteListings() {
      const ids = await api.myFavoriteListingIds();
      if (!ids.length) return [];
      const rows = must(await sb.from('seller_listings').select('*').in('id', ids));
      const names = await profilesMap(rows.map(row => row.seller_id));
      const byId = new Map(rows.map(row => [String(row.id), row]));
      return ids.map(id => byId.get(id)).filter(Boolean).map(row => ({
        ...row,
        seller: names[row.seller_id]?.role === 'admin' ? 'KLB STORE' : (names[row.seller_id]?.username || '')
      }));
    },
    async toggleFavoriteListing(listingId) {
      const userId = await uid();
      const table = sb.from('seller_listing_favorites');
      const existing = must(await table.select('listing_id')
        .eq('user_id', userId).eq('listing_id', listingId).maybeSingle());
      if (existing) {
        must(await table.delete().eq('user_id', userId).eq('listing_id', listingId));
        return false;
      }
      must(await table.insert({ user_id: userId, listing_id: listingId }));
      return true;
    },
    async myListings() {
      const id = await uid();
      return must(await sb.from('seller_listings').select('*').eq('seller_id', id).order('created_at', { ascending: false }));
    },
    async uploadImage(file) {
      const id = await uid();
      const ext = (file.name.split('.').pop() || 'png').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 5) || 'png';
      const path = `${id}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${ext}`;
      const { error } = await sb.storage.from('listing-images').upload(path, file, { contentType: file.type || 'image/png', upsert: false });
      if (error) throw error;
      return sb.storage.from('listing-images').getPublicUrl(path).data.publicUrl;
    },
    async createListing(v) {
      const id = await uid();
      const stock = Number(v.stock);
      if (!Number.isInteger(stock) || stock < 1 || stock > 30) throw new Error('Listing stock must be between 1 and 30');
      const row = must(await sb.from('seller_listings').insert({
        seller_id: id, title: v.title, description: v.description,
        category: v.category, catalog_category: v.catalog_category || 'other',
        catalog_subcategory: v.catalog_subcategory || 'other',
        price: v.price, stock, image_url: v.image_url || null
      }).select().single());
      void notifyAdmins('listing', row.id);
      return row;
    },
    async updateListing(listingId, patch) {
      const next = { ...patch };
      if (Object.prototype.hasOwnProperty.call(next, 'stock')) {
        next.stock = Number(next.stock);
        if (!Number.isInteger(next.stock) || next.stock < 0 || next.stock > 30) throw new Error('Listing stock must be between 0 and 30');
      }
      const row = must(await sb.from('seller_listings').update(next).eq('id', listingId).select().single());
      // Notify only when product content was edited and the DB returned the listing to moderation.
      const contentChanged = ['title', 'description', 'category', 'catalog_category', 'catalog_subcategory', 'price', 'image_url']
        .some((key) => Object.prototype.hasOwnProperty.call(next, key));
      if (contentChanged && row.status === 'pending') void notifyAdmins('listing', row.id);
      return row;
    },

    /* ---------- wallet checkout, escrow and order chats ---------- */
    async createMarketplaceOrder(listingId, quantity = 1, expectedUnitPrice = null) {
      const result = must(await sb.rpc('create_marketplace_order', { p_listing_id: listingId, p_quantity: quantity, p_expected_unit_price: expectedUnitPrice }));
      // Telegram notification is an auxiliary effect. A bot outage never reverses a successful checkout.
      try {
        const notifySession = await B.session();
        if (!notifySession?.access_token) {
          console.warn('KLB Telegram seller notification skipped: no active buyer session token.');
        } else {
          const { data, error } = await sb.functions.invoke('telegram-order-notify', {
            body: { order_id: result.order_id },
            headers: { Authorization: `Bearer ${notifySession.access_token}` }
          });
          if (error) console.warn('KLB Telegram seller notification could not be sent:', error);
          else if (data && data.sent === false) console.warn('KLB Telegram seller notification was not delivered:', data.reason || 'Seller Telegram chat is not linked');
        }
      } catch (err) { console.warn('KLB Telegram seller notification could not be sent:', err); }
      return result;
    },
    async myChats() {
      const id = await uid();
      const chats = must(await sb.from('marketplace_chats').select('*').order('created_at', { ascending: false }));
      if (!chats.length) return [];
      const orderIds = [...new Set(chats.map(c => c.order_id).filter(Boolean))];
      const orders = orderIds.length
        ? must(await sb.from('marketplace_orders').select('*').in('id', orderIds))
        : [];
      const orderMap = Object.fromEntries(orders.map(o => [o.id, o]));
      const otherIds = chats.map(c => c.buyer_id === id ? c.seller_id : c.buyer_id);
      const names = await profilesMap(otherIds);
      const latest = must(await sb.from('marketplace_messages').select('chat_id,body,sender_id,created_at').in('chat_id', chats.map(c => c.id)).order('created_at', { ascending: false }));
      const latestMap = {};
      for (const message of latest) if (!latestMap[message.chat_id]) latestMap[message.chat_id] = message;
      const [disputes, reviews] = await Promise.all([
        must(await sb.from('marketplace_disputes').select('*').in('order_id', orderIds)),
        must(await sb.from('marketplace_reviews').select('*').in('order_id', orderIds))
      ]);
      const disputeMap = Object.fromEntries(disputes.map(d => [d.order_id, d]));
      const reviewMap = Object.fromEntries(reviews.map(r => [r.order_id, r]));
      return chats.map(c => ({
        ...c,
        order: orderMap[c.order_id] || null,
        otherUserId: c.buyer_id === id ? c.seller_id : c.buyer_id,
        otherUsername: names[c.buyer_id === id ? c.seller_id : c.buyer_id]?.username || 'Пользователь',
        latestMessage: latestMap[c.id] || null,
        dispute: disputeMap[c.order_id] || null,
        review: reviewMap[c.order_id] || null
      }));
    },
    async chatMessages(chatId) {
      return must(await sb.from('marketplace_messages').select('id,chat_id,sender_id,body,created_at')
        .eq('chat_id', chatId).order('created_at', { ascending: true }).limit(500));
    },
    async sendChatMessage(chatId, body) {
      const id = await uid();
      const clean = String(body || '').trim();
      if (!clean || clean.length > 4000) throw new Error('Сообщение должно содержать от 1 до 4000 символов.');
      must(await sb.from('marketplace_messages').insert({ chat_id: chatId, sender_id: id, body: clean }));
    },
    async sellerCompleteOrder(orderId) {
      must(await sb.rpc('seller_complete_marketplace_order', { p_order_id: orderId }));
    },
    async confirmOrderReceived(orderId) {
      return must(await sb.rpc('confirm_marketplace_order_received', { p_order_id: orderId }));
    },
    async createReview(orderId, rating, comment) {
      return must(await sb.rpc('create_marketplace_review', {
        p_order_id: orderId, p_rating: Number(rating), p_comment: String(comment || '').trim()
      }));
    },
    async createDispute(orderId, reason, evidencePath = null) {
      const id = must(await sb.rpc('create_marketplace_dispute', {
        p_order_id: orderId, p_reason: String(reason || '').trim(), p_evidence_path: evidencePath
      }));
      void notifyAdmins('dispute', id);
      return id;
    },
    async uploadModerationEvidence(file) {
      if (!file || !/^image\/(png|jpeg|webp)$/.test(file.type)) throw new Error('Прикрепи изображение PNG, JPG или WEBP.');
      if (file.size > 5 * 1024 * 1024) throw new Error('Размер скриншота не должен превышать 5 МБ.');
      const id = await uid();
      const ext = ({ 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp' })[file.type] || 'png';
      const path = `${id}/reports/${Date.now()}-${Math.random().toString(36).slice(2, 9)}.${ext}`;
      const { error } = await sb.storage.from('klb-report-evidence').upload(path, file, { contentType: file.type, upsert: false });
      if (error) throw error;
      return path;
    },
    async createAccountReport(targetUserId, description, evidencePath = null, chatId = null) {
      const id = must(await sb.rpc('create_marketplace_account_report', {
        p_target_user_id: targetUserId, p_description: String(description || '').trim(),
        p_evidence_path: evidencePath, p_chat_id: chatId
      }));
      void notifyAdmins('account_report', id);
      return id;
    },
    async profileDetails(userId) {
      const profile = must(await sb.from('profiles').select('id,username,role,status,bio,moderator_level,trading_disabled,created_at').eq('id', userId).single());
      const stats = must(await sb.rpc('marketplace_public_profile_stats', { p_user_id: userId }));
      const reviews = must(await sb.from('marketplace_reviews').select('id,order_id,reviewer_id,rating,comment,created_at')
        .eq('seller_id', userId).order('created_at', { ascending: false }).limit(50));
      const reviewers = await profilesMap(reviews.map(r => r.reviewer_id));
      return { profile, stats, reviews: reviews.map(r => ({ ...r, reviewer: reviewers[r.reviewer_id]?.username || 'Пользователь' })) };
    },
    async updateMyBio(bio) {
      const id = await uid();
      const clean = String(bio || '').trim();
      if (clean.length > 1000) throw new Error('Описание профиля: максимум 1000 символов.');
      return must(await sb.from('profiles').update({ bio: clean }).eq('id', id).select('bio').single());
    },
    async updateMyUsername(username) {
      const clean = String(username || '').trim();
      if (!/^[A-Za-z0-9_]{3,24}$/.test(clean)) throw new Error('Username must be 3-24 characters');
      const { data, error } = await sb.functions.invoke('klb-profile-username', { body: { username: clean } });
      if (error) throw error;
      // The server changes the synthetic Auth email together with the public profile.
      // Refresh the session so the SDK's cached user record matches the new login.
      const refreshed = await sb.auth.refreshSession();
      if (refreshed.error) console.warn('KLB: username was changed, but the session refresh failed:', refreshed.error);
      return data;
    },
    async createTelegramLinkCode() {
      return must(await sb.rpc('klb_create_telegram_link_code'));
    },
    async telegramLoginCode(code, codeVerifier, redirectUri) {
      if (!code || !codeVerifier || !redirectUri) throw new Error('Не хватает данных возврата Telegram. Начни вход заново.');
      const { data, error } = await sb.functions.invoke('telegram-auth', { body: { code, code_verifier: codeVerifier, redirect_uri: redirectUri } });
      if (error) throw error;
      const { data: verified, error: verifyError } = await sb.auth.verifyOtp({ token_hash: data.token_hash, type: 'magiclink' });
      if (verifyError) throw verifyError;
      return { ...data, session: verified.session };
    },
    async telegramLogin(idToken) {
      if (typeof idToken !== 'string' || idToken.split('.').length !== 3) throw new Error('Некорректный Telegram ID token.');
      const { data, error } = await sb.functions.invoke('telegram-auth', { body: { id_token: idToken } });
      if (error) throw error;
      const { data: verified, error: verifyError } = await sb.auth.verifyOtp({ token_hash: data.token_hash, type: 'magiclink' });
      if (verifyError) throw verifyError;
      return { ...data, session: verified.session };
    },
    async telegramMiniAppLogin(initData) {
      if (typeof initData !== 'string' || !initData) throw new Error('Telegram Mini App не передал initData. Открой KLB STORE через меню бота в Telegram.');
      const { data, error } = await sb.functions.invoke('telegram-auth', { body: { init_data: initData, source: 'miniapp' } });
      if (error) throw error;
      if (!data?.token_hash) throw new Error(data?.error || 'Сервер не вернул токен входа Telegram.');
      const { data: verified, error: verifyError } = await sb.auth.verifyOtp({ token_hash: data.token_hash, type: 'magiclink' });
      if (verifyError) throw verifyError;
      return { ...data, session: verified.session };
    },
    async linkTelegramMiniApp(initData) {
      if (typeof initData !== 'string' || !initData) throw new Error('Telegram Mini App не передал initData.');
      const { data, error } = await sb.functions.invoke('telegram-auth', { body: { init_data: initData, action: 'link', source: 'miniapp' } });
      if (error) throw error;
      return data;
    },

    /* ---------- admin ---------- */
    admin: {
      async deposits() {
        const rows = must(await sb.from('deposit_requests').select('*').order('created_at', { ascending: false }).limit(200));
        const names = await profilesMap(rows.map(r => r.user_id));
        return rows.map(r => ({ id: r.id, userId: r.user_id, username: names[r.user_id]?.username || r.user_id.slice(0, 8), amount: Number(r.amount), code: r.comment_code, bank: '', card: '', status: DEP[r.status] || r.status, created: r.created_at }));
      },
      async reviewDeposit(id, approve) { must(await sb.rpc('admin_review_deposit', { p_request: id, p_approve: approve })); },
      async withdrawals() {
        const rows = must(await sb.from('withdrawal_requests').select('*').order('created_at', { ascending: false }).limit(200));
        const names = await profilesMap(rows.map(r => r.user_id));
        return rows.map(r => ({ id: r.id, userId: r.user_id, username: names[r.user_id]?.username || r.user_id.slice(0, 8), method: r.method === 'usdt_trc20' ? 'usdt' : (r.method === 'sbp_phone' ? 'sbp' : 'bank'), bank: r.bank_name || '', phone: r.phone || '', address: r.crypto_address || '', amount: Number(r.amount), status: WDR[r.status] || r.status, created: r.created_at }));
      },
      async reviewWithdrawal(id, paid) { must(await sb.rpc('admin_review_withdrawal', { p_request: id, p_paid: paid })); },
      async listings() {
        const rows = must(await sb.from('seller_listings').select('*').order('created_at', { ascending: false }).limit(300));
        const names = await profilesMap(rows.map(r => r.seller_id));
        return rows.map(r => ({ id: r.id, userId: r.seller_id, seller: names[r.seller_id]?.username || '', title: r.title, description: r.description, category: r.category, catalogCategory: r.catalog_category || 'other', catalogSubcategory: r.catalog_subcategory || 'other', price: Number(r.price), stock: r.stock, image: r.image_url || '', status: LST[r.status] || r.status, note: r.moderation_note }));
      },
      async setListing(id, patch) {
        const p = { ...patch };
        if (p.status) p.status = LISTING_STATUS_TO_DB[p.status] || p.status;
        return must(await sb.from('seller_listings').update(p).eq('id', id).select().single());
      },
      async deleteListing(id) { must(await sb.from('seller_listings').delete().eq('id', id)); },
      async sellerApplications() {
        const rows = must(await sb.from('seller_applications').select('*').order('created_at', { ascending: false }).limit(200));
        const names = await profilesMap(rows.map(r => r.user_id));
        return rows.map(r => ({
          id: r.id,
          userId: r.user_id,
          name: r.username || r.nickname || names[r.user_id]?.username || '',
          username: names[r.user_id]?.username || r.username || '',
          age: r.age,
          telegram: r.telegram,
          description: r.description,
          benefit: r.benefits || r.benefit || '',
          date: new Date(r.created_at).toLocaleString('ru-RU'),
          status: APP[r.status] || r.status
        }));
      },
      async reviewSeller(app, approve) {
        // Existing deployed schema stores review state in status; reviewed_at/reviewed_by
        // are not present in every KLB migration variant, so do not require those columns.
        const { error } = await sb.from('seller_applications')
          .update({ status: approve ? 'approved' : 'rejected' })
          .eq('id', app.id);
        if (error) throw error;
        // approval and revocation both go through the admin-only RPC (never touch an admin's own role)
        const target = must(await sb.from('profiles').select('role').eq('id', app.userId).single());
        if (target.role !== 'admin') must(await sb.rpc('admin_set_seller', { p_user: app.userId, p_approved: !!approve }));
      },
      async users() {
        const rows = must(await sb.from('profiles').select('id,username,role,status,created_at').order('created_at', { ascending: false }).limit(500));
        const ids = rows.map(r => r.id);
        const walletChunks = [];
        for (let i = 0; i < ids.length; i += 100) walletChunks.push(ids.slice(i, i + 100));
        const walletResults = await Promise.all(walletChunks.map(chunk => sb.from('wallets').select('user_id,available,bonus_available').in('user_id', chunk)));
        const walletRows = walletResults.flatMap(result => must(result));
        const walletMap = Object.fromEntries(walletRows.map(w => [w.user_id, w]));
        return rows.map(r => ({ id: r.id, username: r.username, role: r.role, status: r.status === 'blocked' ? 'Заблокирован' : 'Активен', joined: new Date(r.created_at).toLocaleDateString('ru-RU'), available: Number(walletMap[r.id]?.available || 0), bonus_available: Number(walletMap[r.id]?.bonus_available || 0) }));
      },
      async setBlocked(id, blocked) { must(await sb.rpc('admin_set_user_blocked', { p_user: id, p_blocked: blocked })); },
      async grantBonus(id, amount, reason) { return must(await sb.rpc('klb_admin_grant_bonus', { p_user_id: id, p_amount: amount, p_reason: reason })); },
      async balances() {
        const w = must(await sb.from('wallets').select('user_id,available,bonus_available,reserved,escrow,updated_at').order('updated_at', { ascending: false }).limit(500));
        const names = await profilesMap(w.map(r => r.user_id));
        return w.map(r => ({ userId: r.user_id, username: names[r.user_id]?.username || r.user_id.slice(0, 8), available: Number(r.available), bonus_available: Number(r.bonus_available || 0), reserved: Number(r.reserved), escrow: Number(r.escrow || 0) }));
      },
      async ledger() {
        const rows = must(await sb.from('wallet_ledger').select('*').order('created_at', { ascending: false }).limit(200));
        const names = await profilesMap(rows.map(r => r.user_id));
        return rows.map(r => ({ id: r.id, username: names[r.user_id]?.username || r.user_id.slice(0, 8), operation: r.operation, amount: Number(r.amount), note: r.note, date: r.created_at }));
      },
      async paymentSettings() {
        const r = must(await sb.from('wallet_payment_settings').select('deposit_bank,deposit_card').eq('id', true).maybeSingle());
        return { bank: r?.deposit_bank || '', card: r?.deposit_card || '' };
      },
      async savePaymentSettings(bank, card) {
        const r = must(await sb.from('wallet_payment_settings').update({ deposit_bank: bank, deposit_card: card, updated_at: new Date().toISOString(), updated_by: await uid() }).eq('id', true).select());
        if (!r || !r.length) throw new Error('Настройки не сохранены: нет прав или строка настроек отсутствует.');
      },
      async financialStats() {
        return must(await sb.rpc('marketplace_admin_financial_stats'));
      },
      async accountReports() {
        const rows = must(await sb.from('marketplace_reports').select('*').order('created_at', { ascending: false }).limit(300));
        const names = await profilesMap(rows.flatMap(r => [r.reporter_id, r.target_user_id]));
        return rows.map(r => ({
          ...r,
          reporter: names[r.reporter_id]?.username || r.reporter_id.slice(0, 8),
          target: names[r.target_user_id]?.username || r.target_user_id.slice(0, 8),
          targetRole: names[r.target_user_id]?.role || 'user'
        }));
      },
      async marketplaceDisputes() {
        const rows = must(await sb.from('marketplace_disputes').select('*').order('created_at', { ascending: false }).limit(300));
        if (!rows.length) return [];
        const orderIds = [...new Set(rows.map(r => r.order_id))];
        const orders = must(await sb.from('marketplace_orders').select('*').in('id', orderIds));
        const names = await profilesMap(rows.flatMap(r => [r.buyer_id, r.seller_id]));
        const orderMap = Object.fromEntries(orders.map(o => [o.id, o]));
        return rows.map(r => ({
          ...r, order: orderMap[r.order_id] || null,
          buyer: names[r.buyer_id]?.username || r.buyer_id.slice(0, 8),
          seller: names[r.seller_id]?.username || r.seller_id.slice(0, 8)
        }));
      },
      async disputeDetails(disputeId) {
        const d = must(await sb.from('marketplace_disputes').select('*').eq('id', disputeId).single());
        const [o, messages, names] = await Promise.all([
          sb.from('marketplace_orders').select('*').eq('id', d.order_id).single(),
          sb.from('marketplace_messages').select('id,sender_id,body,created_at').eq('chat_id', d.chat_id).order('created_at', { ascending: true }).limit(500),
          profilesMap([d.buyer_id, d.seller_id])
        ]);
        const order = must(o), transcript = must(messages);
        const senders = await profilesMap(transcript.map(m => m.sender_id));
        return { dispute: d, order, buyer: names[d.buyer_id]?.username || 'Покупатель', seller: names[d.seller_id]?.username || 'Продавец',
          messages: transcript.map(m => ({ ...m, sender: senders[m.sender_id]?.username || 'Администрация' })) };
      },
      async evidenceUrl(path) {
        if (!path) return null;
        const { data, error } = await sb.storage.from('klb-report-evidence').createSignedUrl(path, 1800);
        if (error) throw error;
        return data.signedUrl;
      },
      async resolveAccountReport(reportId, action, note = '') {
        must(await sb.rpc('klb_staff_resolve_report', { p_report_id: reportId, p_action: action, p_note: note }));
      },
      async resolveDispute(disputeId, approve, note = '') {
        must(await sb.rpc('klb_staff_resolve_dispute', { p_dispute_id: disputeId, p_approve: !!approve, p_note: note }));
      },
      async staffAccess() { return must(await sb.rpc('klb_staff_access')); },
      async moderatorHeartbeat(pageName='dashboard') { must(await sb.rpc('klb_moderator_heartbeat', { p_page: pageName })); },
      async moderators() { return must(await sb.rpc('klb_moderator_roster')); },
      async moderatorActivity() { return must(await sb.rpc('klb_moderator_activity_feed')); },
      async assignModerator(username, level) { must(await sb.rpc('klb_assign_moderator', { p_username: username, p_level: Number(level) })); },
      async promoCodes() { return must(await sb.from('marketplace_promo_codes').select('*').order('created_at', { ascending: false }).limit(300)); },
      async createPromoCode(value) { const row = must(await sb.from('marketplace_promo_codes').insert(value).select().single()); must(await sb.rpc('klb_log_moderator_activity', { p_action: 'promo_created', p_target_id: row.id })); return row; },
      async updatePromoCode(id, patch) { const row = must(await sb.from('marketplace_promo_codes').update(patch).eq('id', id).select().single()); const action = patch.is_active === true ? 'promo_enabled' : 'promo_disabled'; must(await sb.rpc('klb_log_moderator_activity', { p_action: action, p_target_id: id })); return row; },
      async partners() { return must(await sb.rpc('klb_admin_partner_roster')); },
      async setPartner(username, partnerType, active=true) { must(await sb.rpc('klb_admin_set_partner', { p_username: username, p_partner_type: partnerType, p_active: !!active })); },
      async createReferralPromo(value) { return must(await sb.rpc('klb_admin_create_referral_promo', {
        p_username: value.username, p_promo_name: value.promo_name, p_code: value.code,
        p_discount_percent: Number(value.discount_percent), p_commission_percent: Number(value.commission_percent),
        p_expires_at: value.expires_at || null
      })); },
      async updateReferralPromo(id, patch) { must(await sb.rpc('klb_admin_update_referral_promo', {
        p_promo_id: id, p_promo_name: patch.promo_name,
        p_discount_percent: Number(patch.discount_percent),
        p_commission_percent: Number(patch.commission_percent),
        p_expires_at: patch.expires_at || null, p_is_active: !!patch.is_active
      })); }
    }
  };
  api.staffAccess = () => sb.rpc('klb_staff_access').then(({data,error})=>{if(error)throw error;return data;});
  Object.assign(B, api);
})();
