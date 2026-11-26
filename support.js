/* KLB STORE — Поддержка. Общий модуль для сайта (вкладка «Чаты») и админ-панели.
   Пользователь видит только свои обращения; администраторы и модераторы 1/2 уровня — все.
   Права проверяются в базе (klb-support-chat.sql), здесь только интерфейс. */
(function () {
  const SB = window.KLBBackend && window.KLBBackend.configured ? window.KLBBackend : null;
  const ICON = 'support-icon.png';
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fmt = (d) => { try { return new Date(d).toLocaleString('ru-RU', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }); } catch { return ''; } };
  const err = (e) => (SB && SB.ruError ? SB.ruError(e) : String((e && e.message) || e || 'Ошибка'));
  let timer = null;
  const stopTimer = () => { clearInterval(timer); timer = null; };

  function statusBadge(t, staff) {
    if (t.status === 'closed') return ['closed', 'Закрыто'];
    if (staff) return t.needs_reply ? ['wait', 'Ждёт ответа'] : ['ok', 'Отвечено'];
    return t.last_sender_staff ? ['ok', 'Есть ответ'] : ['wait', 'Ожидает ответа'];
  }

  async function mount(host, opts = {}) {
    if (!SB || !SB.support) { host.innerHTML = '<p class="ksup-muted">Поддержка станет доступна после подключения Supabase.</p>'; return; }
    stopTimer();
    const st = { staff: false, filter: null, tickets: [] };
    const fail = (e) => { host.innerHTML = '<div class="ksup"><p class="ksup-error">' + esc(err(e)) + '</p>' + (opts.onBack ? '<button class="ksup-back" data-act="back">← Все чаты</button>' : '') + '</div>'; const b = host.querySelector('[data-act=back]'); if (b) b.onclick = opts.onBack; };

    async function showList() {
      stopTimer();
      host.innerHTML = '<p class="ksup-muted">Загружаем…</p>';
      let data;
      try { data = await SB.support.tickets(); } catch (e) { return fail(e); }
      st.staff = !!data.is_staff;
      st.tickets = data.tickets || [];
      const waiting = st.tickets.filter((t) => t.needs_reply).length;
      const open = st.tickets.filter((t) => t.status === 'open').length;
      const closed = st.tickets.length - open;
      if (st.filter === null) st.filter = st.staff ? (waiting ? 'wait' : 'all') : 'all';
      const shown = st.tickets.filter((t) => st.filter === 'wait' ? t.needs_reply : st.filter === 'open' ? t.status === 'open' : st.filter === 'closed' ? t.status === 'closed' : true);
      const chip = (k, label, n) => '<button class="ksup-chip' + (st.filter === k ? ' active' : '') + '" data-filter="' + k + '">' + label + ' <b>' + n + '</b></button>';
      host.innerHTML =
        '<div class="ksup">' +
        '<div class="ksup-head">' +
        (opts.onBack ? '<button class="ksup-back" data-act="back">← Все чаты</button>' : '') +
        '<div class="ksup-title"><img class="ksup-ico" src="' + ICON + '" alt=""><div><h3>Поддержка</h3><p>' +
        (st.staff ? 'Все обращения пользователей' : 'Напиши нам: поможем с заказом, оплатой или аккаунтом') + '</p></div></div>' +
        (st.staff ? '' : '<button class="ksup-primary" data-act="new">＋ Новое обращение</button>') +
        '</div>' +
        (st.staff ? '<div class="ksup-chips">' + chip('wait', 'Ждут ответа', waiting) + chip('open', 'Открытые', open) + chip('closed', 'Закрытые', closed) + chip('all', 'Все', st.tickets.length) + '</div>' : '') +
        '<div class="ksup-list">' +
        (shown.length ? shown.map((t) => {
          const b = statusBadge(t, st.staff);
          return '<button class="ksup-item" data-id="' + esc(t.id) + '"><span class="ksup-item-main"><b>' + esc(t.subject) + '</b><small>' +
            (st.staff ? esc(t.username || '—') + ' · ' : '') + esc(t.last_body || '') + '</small></span>' +
            '<span class="ksup-item-side"><span class="ksup-status ' + b[0] + '">' + b[1] + '</span><small>' + fmt(t.last_message_at) + '</small></span></button>';
        }).join('') : '<p class="ksup-muted">' + (st.staff ? 'В этом списке пока ничего нет.' : 'Обращений пока нет. Нажми «Новое обращение», если нужна помощь.') + '</p>') +
        '</div></div>';
      const back = host.querySelector('[data-act=back]'); if (back) back.onclick = opts.onBack;
      const nw = host.querySelector('[data-act=new]'); if (nw) nw.onclick = showNew;
      host.querySelectorAll('[data-filter]').forEach((b) => (b.onclick = () => { st.filter = b.dataset.filter; showList(); }));
      host.querySelectorAll('[data-id]').forEach((b) => (b.onclick = () => showTicket(b.dataset.id)));
    }

    function showNew() {
      stopTimer();
      host.innerHTML =
        '<div class="ksup"><div class="ksup-head"><button class="ksup-back" data-act="list">← Все обращения</button>' +
        '<div class="ksup-title"><img class="ksup-ico" src="' + ICON + '" alt=""><div><h3>Новое обращение</h3><p>Опиши, что случилось. Ответ придёт сюда, в чат поддержки.</p></div></div></div>' +
        '<form class="ksup-form ksup-newform"><label>Тема<input name="subject" required minlength="3" maxlength="120" placeholder="Например: не пришёл заказ"></label>' +
        '<label>Сообщение<textarea name="body" rows="5" required maxlength="4000" placeholder="Расскажи подробнее: что произошло, номер заказа, ник продавца…"></textarea></label>' +
        '<button class="ksup-primary" type="submit">Отправить в поддержку</button><p class="ksup-error" data-err></p></form></div>';
      host.querySelector('[data-act=list]').onclick = showList;
      const f = host.querySelector('form');
      f.onsubmit = async (e) => {
        e.preventDefault();
        const btn = f.querySelector('button'); btn.disabled = true;
        try { const r = await SB.support.create(f.elements.subject.value, f.elements.body.value); await showTicket(r.ticket_id); }
        catch (x) { f.querySelector('[data-err]').textContent = err(x); btn.disabled = false; }
      };
    }

    async function showTicket(id) {
      stopTimer();
      host.innerHTML = '<p class="ksup-muted">Загружаем…</p>';
      let data;
      try { data = await SB.support.messages(id); } catch (e) { return fail(e); }
      st.staff = !!data.is_staff;
      const t = data.ticket;
      let sig = '';
      host.innerHTML =
        '<div class="ksup"><div class="ksup-head"><button class="ksup-back" data-act="list">← Все обращения</button>' +
        '<div class="ksup-title"><img class="ksup-ico" src="' + ICON + '" alt=""><div><h3 data-subject></h3><p data-meta></p></div></div>' +
        '<span class="ksup-status" data-status></span></div>' +
        '<div class="ksup-msgs" data-msgs></div>' +
        '<form class="ksup-form ksup-reply"><textarea name="body" rows="2" required maxlength="4000" placeholder="' + (st.staff ? 'Ответ пользователю…' : 'Напиши сообщение…') + '"></textarea>' +
        '<button class="ksup-primary" type="submit">Отправить</button></form>' +
        '<p class="ksup-error" data-err></p>' +
        '<div class="ksup-actions"><button class="ksup-ghost" data-act="toggle"></button></div></div>';
      const $q = (s) => host.querySelector(s);
      $q('[data-act=list]').onclick = () => { if (opts.panel && opts.onList) opts.onList(); showList(); };

      function paint(d) {
        const tk = d.ticket, msgs = d.messages || [];
        $q('[data-subject]').textContent = tk.subject;
        $q('[data-meta]').textContent = (st.staff ? 'от ' + (tk.username || '—') + ' · ' : '') + 'создано ' + fmt(tk.created_at);
        const b = $q('[data-status]'); b.className = 'ksup-status ' + (tk.status === 'closed' ? 'closed' : 'ok'); b.textContent = tk.status === 'closed' ? 'Закрыто' : 'Открыто';
        const tg = $q('[data-act=toggle]');
        tg.textContent = tk.status === 'closed' ? 'Открыть обращение заново' : 'Закрыть обращение';
        tg.hidden = tk.status === 'closed' && !st.staff;
        tg.dataset.next = tk.status === 'closed' ? 'open' : 'closed';
        const nsig = msgs.length + ':' + (msgs.length ? msgs[msgs.length - 1].id : '') + ':' + tk.status;
        if (nsig === sig) return;
        sig = nsig;
        const box = $q('[data-msgs]');
        const nearEnd = box.scrollHeight - box.scrollTop - box.clientHeight < 90 || !box.children.length;
        box.innerHTML = msgs.map((m) =>
          '<div class="ksup-msg' + (m.mine ? ' mine' : '') + (m.is_staff ? ' staff' : '') + '"><small class="ksup-name">' + esc(m.is_staff && st.staff ? m.sender_name + ' · поддержка' : m.sender_name) + '</small>' +
          '<span>' + esc(m.body).replace(/\n/g, '<br>') + '</span><small class="ksup-time">' + fmt(m.created_at) + '</small></div>').join('');
        if (tk.status === 'closed') box.insertAdjacentHTML('beforeend', '<p class="ksup-closed-note">Обращение закрыто.' + (st.staff ? '' : ' Если вопрос остался, просто напиши сообщение ниже: обращение откроется снова.') + '</p>');
        if (nearEnd) box.scrollTop = box.scrollHeight;
      }
      paint({ ticket: t, messages: data.messages });
      const first = $q('[data-msgs]'); first.scrollTop = first.scrollHeight;

      const form = $q('form'), ta = form.elements.body;
      form.onsubmit = async (e) => {
        e.preventDefault();
        const body = ta.value.trim(); if (!body) return;
        const btn = form.querySelector('button'); btn.disabled = true; $q('[data-err]').textContent = '';
        try { await SB.support.send(id, body); ta.value = ''; paint(await SB.support.messages(id)); const bx = $q('[data-msgs]'); bx.scrollTop = bx.scrollHeight; }
        catch (x) { $q('[data-err]').textContent = err(x); }
        btn.disabled = false;
      };
      ta.addEventListener('keydown', (e) => { if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') form.requestSubmit(); });
      $q('[data-act=toggle]').onclick = async (e) => {
        const btn = e.currentTarget; btn.disabled = true;
        try { await SB.support.setStatus(id, btn.dataset.next); paint(await SB.support.messages(id)); } catch (x) { $q('[data-err]').textContent = err(x); }
        btn.disabled = false;
      };
      timer = setInterval(async () => {
        if (!host.isConnected) { stopTimer(); return; }
        try { paint(await SB.support.messages(id)); } catch { /* временная ошибка сети — пробуем в следующий раз */ }
      }, 7000);
    }

    if (opts.ticketId) await showTicket(opts.ticketId); else await showList();
  }

  // Строка «Поддержка» в начале списка во вкладке «Чаты».
  async function chatRow() {
    let a = null;
    try { a = SB && SB.support ? await SB.support.access() : null; } catch { a = null; }
    const staff = !!(a && a.is_staff);
    const n = staff ? Number(a.waiting_count || 0) : 0;
    return '<button class="chat-list-item ksup-row" data-open-support><img class="ksup-ico" src="' + ICON + '" alt="">' +
      '<span class="chat-list-main"><b>Поддержка</b><small>' + (staff ? 'Все обращения пользователей' : 'Помощь с заказами, оплатой и аккаунтом') + '</small>' +
      (staff ? '<small class="chat-last-message">Ждут ответа: ' + n + ' · открытых: ' + Number(a.open_count || 0) + '</small>' : '') + '</span>' +
      (n ? '<span class="ksup-badge">' + n + '</span>' : '<span class="ksup-arrow">›</span>') + '</button>';
  }
  function bindRow(host) {
    host.querySelectorAll('[data-open-support]').forEach((b) => (b.onclick = () => openModal()));
  }
  function openModal(ticketId) {
    const app = window.KLBApp;
    if (!app || typeof app.modal !== 'function') return;
    app.modal('Поддержка', '<div id="ksupHost"></div>');
    const host = document.getElementById('ksupHost');
    if (host) mount(host, { ticketId, onBack: () => app.openChats() });
  }

  window.KLBSupport = { mount, chatRow, bindRow, openModal, stop: stopTimer };
})();
