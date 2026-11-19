/* KLB STORE Supabase client adapter.
   Compatible with the database tables created in the current Supabase SQL Editor setup.
   This is API groundwork; storefront/admin UI still needs to be wired to these calls. */
(() => {
  const cfg = window.KLB_SUPABASE_CONFIG;
  if (!cfg?.url || !cfg?.anonKey || !window.supabase?.createClient) {
    window.KLBBackend = { configured: false, message: 'Supabase SDK/config missing.' };
    return;
  }
  const client = window.supabase.createClient(cfg.url, cfg.anonKey);
  const emailForUsername = (username) =>
    `${String(username).trim().toLowerCase().replace(/[^a-z0-9_]/g, '')}@login.klbstore.invalid`;
  const unwrap = async (query) => {
    const { data, error } = await query;
    if (error) throw error;
    return data;
  };
  const api = {
    configured: true,
    client,
    emailForUsername,
    async register(username, password) {
      const clean = String(username || '').trim();
      if (!/^[a-zA-Z0-9_]{3,24}$/.test(clean)) throw new Error('Логин: 3–24 символа, латиница, цифры и _');
      if (String(password).length < 8) throw new Error('Пароль должен быть не короче 8 символов.');
      const { data, error } = await client.auth.signUp({
        email: emailForUsername(clean), password,
        options: { data: { username: clean, display_name: clean } }
      });
      if (error) throw error;
      if (!data.user) throw new Error('Регистрация не завершилась. Проверь настройки подтверждения регистрации.');
      return data.user;
    },
    async login(username, password) {
      const { data, error } = await client.auth.signInWithPassword({
        email: emailForUsername(username), password
      });
      if (error) throw error;
      const profile = await api.profile();
      if (!profile) { await client.auth.signOut(); throw new Error('Профиль не найден. Обратись к администратору.'); }
      return profile;
    },
    async logout() { const { error } = await client.auth.signOut(); if (error) throw error; },
    async session() {
      const { data, error } = await client.auth.getSession();
      if (error) throw error;
      return data.session;
    },
    async profile() {
      const session = await api.session();
      if (!session) return null;
      return unwrap(client.from('profiles').select('*').eq('id', session.user.id).single());
    },
    async isAdmin() {
      const p = await api.profile();
      return p?.role === 'admin';
    },
    async products() {
      return unwrap(client.from('products').select('*').eq('status','active').order('created_at',{ascending:false}));
    },
    async submitSellerApplication(payload) {
      const session = await api.session();
      if (!session) throw new Error('Войдите в аккаунт, чтобы подать заявку.');
      const profile = await api.profile();
      return unwrap(client.from('seller_applications').insert({
        user_id: session.user.id,
        username: profile.username,
        description: payload.description,
        benefits: payload.benefits,
        age: Number(payload.age),
        telegram: payload.telegram,
        status: 'pending'
      }).select().single());
    },
    async mySellerApplications() {
      return unwrap(client.from('seller_applications').select('*').order('created_at',{ascending:false}));
    },
    async adminSellerApplications() {
      if (!await api.isAdmin()) throw new Error('Недостаточно прав.');
      return unwrap(client.from('seller_applications').select('*').order('created_at',{ascending:false}));
    },
    async reviewSellerApplication(id, approved) {
      if (!await api.isAdmin()) throw new Error('Недостаточно прав.');
      const app = await unwrap(client.from('seller_applications')
        .update({status: approved ? 'approved' : 'rejected', updated_at: new Date().toISOString()})
        .eq('id', id).select().single());
      if (approved) {
        await unwrap(client.from('profiles').update({role:'seller'}).eq('id', app.user_id));
      }
      return app;
    },
    async myOrders() {
      return unwrap(client.from('orders').select('*').order('created_at',{ascending:false}));
    },
    async favorites() {
      const rows = await unwrap(client.from('favorites').select('product_id'));
      return rows.map(row => row.product_id);
    },
    async toggleFavorite(productId) {
      const ids = await api.favorites();
      if (ids.includes(productId)) {
        await unwrap(client.from('favorites').delete().eq('product_id',productId));
        return false;
      }
      await unwrap(client.from('favorites').insert({product_id:productId}));
      return true;
    },
    async adminProducts() {
      if (!await api.isAdmin()) throw new Error('Недостаточно прав.');
      return unwrap(client.from('products').select('*').order('created_at',{ascending:false}));
    },
    async adminOrders() {
      if (!await api.isAdmin()) throw new Error('Недостаточно прав.');
      return unwrap(client.from('orders').select('*').order('created_at',{ascending:false}));
    },
    async adminProfiles() {
      if (!await api.isAdmin()) throw new Error('Недостаточно прав.');
      return unwrap(client.from('profiles').select('*').order('created_at',{ascending:false}));
    }
  };
  window.KLBBackend = api;
})();
