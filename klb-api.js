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
    'Listing unavailable': 'Объявление больше недоступно.',
    'Listing price changed': 'Цена изменилась. Обнови каталог и попробуй ещё раз.',
    'Not enough stock': 'Недостаточно товара в наличии.',
    'Cannot buy your own listing': 'Нельзя купить собственное объявление.',
    'Invalid quantity': 'Некорректное количество товара.',
    'Order unavailable': 'Заказ не найден или у тебя нет к нему доступа.',
    'Order is not awaiting seller completion': 'Этот заказ уже обработан или не ожидает выполнения.',
    'Seller has not confirmed completion': 'Продавец ещё не подтвердил выполнение заказа.',
    'Escrow balance mismatch': 'Не удалось сверить удержанные средства. Обратись в поддержку.',

    'Invalid TRC20 address': 'Проверь адрес USDT TRC20.',
    'Bank and phone required': 'Укажи банк и номер телефона.',
    'Unsupported method': 'Неподдерживаемый способ вывода.',
    'Admin only': 'Недостаточно прав.',
    'Request unavailable': 'Заявка уже обработана или недоступна.',
    'Account is blocked': 'Аккаунт заблокирован.',
    'Only moderators can publish listings': 'Публиковать объявления может только модератор.',
    'Cannot block yourself': 'Нельзя заблокировать самого себя.',
    'Profile not found': 'Профиль не найден.',
    'Invalid login credentials': 'Неверный логин или пароль.',
    'User already registered': 'Этот логин уже занят.',
    'Failed to fetch': 'Нет соединения с сервером.'
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
      const r = must(await sb.from('wallets').select('available,reserved,escrow').eq('user_id', id).maybeSingle());
      return { available: Number(r?.available || 0), reserved: Number(r?.reserved || 0), escrow: Number(r?.escrow || 0) };
    },
    async ledger() { return must(await sb.from('wallet_ledger').select('*').order('created_at', { ascending: false }).limit(100)); },
    async depositInstructions() {
      const r = must(await sb.rpc('get_deposit_instructions'));
      const row = Array.isArray(r) ? r[0] : r;
      return { bank: row?.bank || '', details: row?.card_or_details || '' };
    },
    async createDeposit(amount) { return must(await sb.rpc('create_deposit_request', { p_amount: amount })); },
    async markDepositChecking(id) { must(await sb.rpc('mark_deposit_checking', { p_request: id })); },
    async createWithdrawal({ method, amount, bank, phone, address }) {
      return must(await sb.rpc('create_withdrawal_request', {
        p_method: method === 'usdt' ? 'usdt_trc20' : 'bank_phone', p_amount: amount,
        p_bank: method === 'usdt' ? null : bank, p_phone: method === 'usdt' ? null : phone, p_address: method === 'usdt' ? address : null
      }));
    },
    async myDeposits() { return must(await sb.from('deposit_requests').select('*').order('created_at', { ascending: false }).limit(50)); },
    async myWithdrawals() { return must(await sb.from('withdrawal_requests').select('*').order('created_at', { ascending: false }).limit(50)); },

    /* ---------- seller applications (user) ---------- */
    async myApplication() {
      const id = await uid();
      const rows = must(await sb.from('seller_applications').select('*').eq('user_id', id).order('created_at', { ascending: false }).limit(1));
      return rows[0] || null;
    },
    async applyForSeller({ nickname, description, benefit, age, telegram }) {
      const id = await uid();
      // The deployed KLB schema uses username + benefits (plural), not nickname + benefit.
      return must(await sb.from('seller_applications').insert({
        user_id: id, username: nickname, description, benefits: benefit, age, telegram
      }).select().single());
    },

    /* ---------- listings ---------- */
    async catalog() {
      const rows = must(await sb.from('seller_listings').select('*').eq('status', 'active').order('created_at', { ascending: false }));
      const names = await profilesMap(rows.map(r => r.seller_id));
      return rows.map(r => ({
        ...r,
        seller: names[r.seller_id]?.role === 'admin' ? 'KLB STORE' : (names[r.seller_id]?.username || '')
      }));
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
      return must(await sb.from('seller_listings').insert({ seller_id: id, title: v.title, description: v.description, category: v.category, price: v.price, stock: v.stock, image_url: v.image_url || null }).select().single());
    },
    async updateListing(listingId, patch) { return must(await sb.from('seller_listings').update(patch).eq('id', listingId).select().single()); },

    /* ---------- wallet checkout, escrow and order chats ---------- */
    async createMarketplaceOrder(listingId, quantity = 1, expectedUnitPrice = null) {
      return must(await sb.rpc('create_marketplace_order', { p_listing_id: listingId, p_quantity: quantity, p_expected_unit_price: expectedUnitPrice }));
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
      return chats.map(c => ({
        ...c,
        order: orderMap[c.order_id] || null,
        otherUsername: names[c.buyer_id === id ? c.seller_id : c.buyer_id]?.username || 'Пользователь',
        latestMessage: latestMap[c.id] || null
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
        return rows.map(r => ({ id: r.id, userId: r.user_id, username: names[r.user_id]?.username || r.user_id.slice(0, 8), method: r.method === 'usdt_trc20' ? 'usdt' : 'bank', bank: r.bank_name || '', phone: r.phone || '', address: r.crypto_address || '', amount: Number(r.amount), status: WDR[r.status] || r.status, created: r.created_at }));
      },
      async reviewWithdrawal(id, paid) { must(await sb.rpc('admin_review_withdrawal', { p_request: id, p_paid: paid })); },
      async listings() {
        const rows = must(await sb.from('seller_listings').select('*').order('created_at', { ascending: false }).limit(300));
        const names = await profilesMap(rows.map(r => r.seller_id));
        return rows.map(r => ({ id: r.id, userId: r.seller_id, seller: names[r.seller_id]?.username || '', title: r.title, description: r.description, category: r.category, price: Number(r.price), stock: r.stock, image: r.image_url || '', status: LST[r.status] || r.status, note: r.moderation_note }));
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
        return rows.map(r => ({ id: r.id, username: r.username, role: r.role, status: r.status === 'blocked' ? 'Заблокирован' : 'Активен', joined: new Date(r.created_at).toLocaleDateString('ru-RU') }));
      },
      async setBlocked(id, blocked) { must(await sb.rpc('admin_set_user_blocked', { p_user: id, p_blocked: blocked })); },
      async balances() {
        const w = must(await sb.from('wallets').select('user_id,available,reserved,escrow,updated_at').order('updated_at', { ascending: false }).limit(500));
        const names = await profilesMap(w.map(r => r.user_id));
        return w.map(r => ({ userId: r.user_id, username: names[r.user_id]?.username || r.user_id.slice(0, 8), available: Number(r.available), reserved: Number(r.reserved), escrow: Number(r.escrow || 0) }));
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
      }
    }
  };
  Object.assign(B, api);
})();
