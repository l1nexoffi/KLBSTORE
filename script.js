(()=>{
const SB=window.KLBBackend&&window.KLBBackend.configured?window.KLBBackend:null;let walletBal=0,walletReserved=0,walletEscrow=0;
const STORE='klb_users',SESSION='klb_current_user',SELLERS='klb_sellers',ORDERS='klb_orders',LISTINGS='klb_listings',FAV='klb_favorites',PENDING_CHAT='klb_pending_chat';
let remoteFavoriteIds = new Set();
const requestedChat=new URLSearchParams(location.search).get('chat');
if(requestedChat&&/^[0-9a-f-]{20,}$/i.test(requestedChat)){sessionStorage.setItem(PENDING_CHAT,requestedChat);const cleanUrl=location.pathname+location.hash;history.replaceState({},'',cleanUrl);}
function openPendingChatIfReady(){const chatId=sessionStorage.getItem(PENDING_CHAT);if(!chatId)return;if(!current){authDialog('login');notify('Войди в аккаунт продавца или покупателя — затем откроется нужный чат.');return;}sessionStorage.removeItem(PENDING_CHAT);openChats(chatId);}
const read=(k,d=[])=>{try{return JSON.parse(localStorage.getItem(k)??JSON.stringify(d))}catch{return d}},write=(k,v)=>localStorage.setItem(k,JSON.stringify(v));
let users=read(STORE,[]);
let current=SB?null:read(SESSION,null);if(current&&!users.some(u=>u.id===current.id&&u.status!=='Заблокирован')){current=null;localStorage.removeItem(SESSION)}
const $=s=>document.querySelector(s),toast=$('#toast');let toastTimer,chatRefreshTimer=null;
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const KLB_CATALOG_CATEGORIES = [
  {slug:'fortnite',name:'Fortnite',mark:'F',description:'Аккаунты, подарки, наборы, предметы и услуги Fortnite',subs:[['accounts','Аккаунты'],['gifts','Подарки'],['bundles','Наборы'],['battle-pass','Боевой пропуск'],['subscriptions','Подписки'],['boost','Буст'],['services','Услуги'],['items','Предметы'],['twitch-drops','Twitch Drops'],['design','Дизайн'],['other','Другое']]},
  {slug:'steam',name:'Steam',mark:'S',description:'Игры, аккаунты, пополнение и цифровые услуги Steam',subs:[['games','Игры'],['accounts','Аккаунты'],['top-up','Пополнение баланса'],['region-change','Смена региона'],['rewards','Награды Steam'],['items','Предметы'],['services','Услуги'],['other','Другое']]},
  {slug:'roblox',name:'Roblox',mark:'R',description:'Robux, аккаунты, предметы и услуги Roblox',subs:[['robux','Robux'],['accounts','Аккаунты'],['subscriptions','Подписки'],['items','Предметы'],['boost','Буст'],['services','Услуги'],['other','Другое']]},
  {slug:'claude',name:'Claude',mark:'✳',description:'Подписки, аккаунты и услуги Claude',subs:[['services','Услуги'],['accounts','Аккаунты'],['subscriptions','Подписки'],['clean-accounts','Чистые аккаунты'],['other','Другое']]},
  {slug:'gta6',name:'GTA VI',mark:'VI',description:'Цифровые товары, ключи и услуги GTA',subs:[['games','Игры'],['accounts','Аккаунты'],['keys','Ключи'],['currency','Валюта и предметы'],['services','Услуги'],['other','Другое']]},
  {slug:'playstation',name:'PlayStation',mark:'P',description:'Игры, аккаунты, пополнение и подписки PlayStation',subs:[['games','Игры'],['accounts','Аккаунты'],['top-up','Пополнение кошелька'],['subscriptions','Подписки'],['region-change','Смена региона'],['services','Услуги'],['other','Другое']]},
  {slug:'chatgpt',name:'ChatGPT',mark:'◎',description:'Подписки, аккаунты и цифровые услуги ChatGPT',subs:[['subscriptions','Подписки'],['accounts','Аккаунты'],['services','Услуги'],['other','Другое']]},
  {slug:'telegram',name:'Telegram',mark:'➤',description:'Telegram Premium, подарки и цифровые услуги',subs:[['subscriptions','Premium'],['gifts','Подарки'],['accounts','Аккаунты'],['services','Услуги'],['other','Другое']]},
  {slug:'brawl-stars',name:'Brawl Stars',mark:'★',description:'Аккаунты, предметы и услуги Brawl Stars',subs:[['accounts','Аккаунты'],['items','Предметы'],['boost','Буст'],['services','Услуги'],['other','Другое']]},
  {slug:'tiktok',name:'TikTok',mark:'♪',description:'Аккаунты и услуги продвижения TikTok',subs:[['accounts','Аккаунты'],['services','Услуги'],['other','Другое']]},
  {slug:'other',name:'Другое',mark:'＋',description:'Другие цифровые товары и услуги',subs:[['keys','Ключи и коды'],['accounts','Аккаунты'],['subscriptions','Подписки'],['services','Услуги'],['digital-goods','Цифровые товары'],['other','Другое']]}
];
let activeRootCategory=null, activeSubcategory='all';
const categoryForSlug=slug=>KLB_CATALOG_CATEGORIES.find(c=>c.slug===slug)||KLB_CATALOG_CATEGORIES.find(c=>c.slug==='other');
const catalogSubcategoryName=(root,slug)=>categoryForSlug(root)?.subs.find(s=>s[0]===slug)?.[1]||'Другое';
const legacyListingKind=sub=>({accounts:'accounts',keys:'keys',subscriptions:'subscriptions',services:'services',games:'games',items:'games',gifts:'games',bundles:'games','battle-pass':'games',boost:'services','twitch-drops':'games',design:'services','top-up':'services','region-change':'services',rewards:'games',robux:'games',currency:'games','clean-accounts':'accounts',rent:'services','digital-goods':'other'}[sub]||'other');
function organicListingCompare(a,b){const ar=Number(a.seller_rating||0),br=Number(b.seller_rating||0);if(br!==ar)return br-ar;const ac=Number(a.seller_review_count||0),bc=Number(b.seller_review_count||0);if(bc!==ac)return bc-ac;const ap=Number(a.price||0),bp=Number(b.price||0);if(ap!==bp)return ap-bp;return String(b.created_at||'').localeCompare(String(a.created_at||''));}
function arrangeCategoryListings(items){
  const promoted=items.filter(x=>Number(x.promotion_rank)>0).sort((a,b)=>Number(a.promotion_rank)-Number(b.promotion_rank)||String(b.promoted_at||'').localeCompare(String(a.promoted_at||'')));
  const organic=items.filter(x=>!(Number(x.promotion_rank)>0)).sort(organicListingCompare);
  const slots=new Map();
  promoted.forEach(item=>{let position=Math.max(1,Number(item.promotion_rank)||1);while(slots.has(position))position++;slots.set(position,item)});
  const out=[];let freeIndex=0;
  for(let position=1;out.length<items.length;position++){if(slots.has(position))out.push(slots.get(position));else if(freeIndex<organic.length)out.push(organic[freeIndex++]);else{const next=promoted.find(item=>!out.includes(item));if(next)out.push(next);else break}}
  return out;
}

function notify(m){toast.textContent=m;toast.classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>toast.classList.remove('show'),3000)}
function syncModalViewport(){const vv=window.visualViewport;const h=vv&&vv.height?vv.height:window.innerHeight;const top=vv&&Number.isFinite(vv.offsetTop)?vv.offsetTop:0;document.documentElement.style.setProperty('--klb-vh',`${Math.round(h)}px`);document.documentElement.style.setProperty('--klb-vv-top',`${Math.round(top)}px`)}
if(window.visualViewport){window.visualViewport.addEventListener('resize',syncModalViewport);window.visualViewport.addEventListener('scroll',syncModalViewport)}window.addEventListener('resize',syncModalViewport);window.addEventListener('orientationchange',()=>setTimeout(syncModalViewport,120));
function modal(title,body,actions=''){clearInterval(chatRefreshTimer);chatRefreshTimer=null;syncModalViewport();const m=$('#appModal');document.documentElement.classList.add('klb-modal-open');document.body.classList.add('klb-modal-open');m.innerHTML=`<div class="modal-backdrop" data-close></div><section class="app-modal" role="dialog" aria-modal="true" aria-label="${esc(title)}"><button class="modal-x" type="button" data-close aria-label="Закрыть окно">×</button><h2>${title}</h2>${body}${actions}</section>`;m.classList.add('open');m.querySelectorAll('[data-close]').forEach(el=>el.addEventListener('click',e=>{e.preventDefault();e.stopPropagation();closeModal()}));const panel=m.querySelector('.app-modal');panel.addEventListener('click',e=>e.stopPropagation());panel.addEventListener('focusin',e=>{if(e.target.matches('input,textarea,select'))setTimeout(()=>{try{e.target.scrollIntoView({block:'nearest',inline:'nearest',behavior:'smooth'})}catch{}},180)});}
function closeModal(){clearInterval(chatRefreshTimer);chatRefreshTimer=null;const m=$('#appModal');m.classList.remove('open');m.innerHTML='';document.documentElement.classList.remove('klb-modal-open');document.body.classList.remove('klb-modal-open')}
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&$('#appModal').classList.contains('open'))closeModal()});
function refreshHeader(){
  const btn=$('#loginBtn'),balanceBtn=$('#balanceBtn'),balanceText=$('#headerBalance'),chatsBtn=$('#chatsBtn'),footerAdmin=$('#footerAdminLink');
  const staff=!!current&&(current.role==='admin'||Number(current.moderator_level||0)>0);
  if(footerAdmin)footerAdmin.hidden=!staff;
  if(chatsBtn){chatsBtn.hidden=!current;chatsBtn.onclick=()=>openChats()}
  if(!current){btn.innerHTML='Войти <span>↗</span>';btn.onclick=()=>authDialog('login');balanceBtn.hidden=true;return}
  btn.innerHTML=`<span class="user-pill"><span class="user-avatar">${esc(current.username[0].toUpperCase())}</span>${esc(current.username)} <span>⌄</span></span>`;
  btn.onclick=profileMenu;balanceBtn.hidden=false;balanceText.textContent=wallet(current.id).toLocaleString('ru-RU')+' ₽';balanceBtn.onclick=walletDialog;
}
function profileMenu(){if(SB){refreshProfile().then(()=>{if(current)profileMenuView()});return}profileMenuView()}
function profileMenuView(){modal(`Привет, ${esc(current.username)}!`, `<div class="profile-menu"><button data-profile="profile">👤 Мой профиль</button><button data-profile="deals">⇄ Мои сделки</button><button data-profile="favorites">♡ Избранное</button><button data-profile="chats">✉ Чаты и сделки</button><button data-profile="wallet">◈ Кошелёк · ${wallet(current.id).toLocaleString('ru-RU')} ₽</button>${current.role==='seller'?'<button data-profile="seller">♙ Панель продавца</button>':''}${current.role==='admin'?'<button data-profile="store">🏪 Объявления KLB STORE</button>':''}${(current.role==='admin'||Number(current.moderator_level||0)>0)?'<button class="admin-shortcut" data-profile="admin">🛡 Войти в админ-панель</button>':''}<button class="logout-action" data-profile="logout">↪ Выйти</button></div>`);document.querySelectorAll('#appModal [data-profile]').forEach(b=>b.addEventListener('click',()=>{const action=b.dataset.profile;closeModal();switch(action){case'profile':showProfile();break;case'deals':showDeals();break;case'favorites':showFavorites();break;case'chats':openChats();break;case'wallet':walletDialog();break;case'seller':case'store':sellerDashboard();break;case'admin':location.href='admin-login.html';break;case'logout':if(SB)SB.logout().catch(()=>{});walletBal=0;walletReserved=0;walletEscrow=0;current=null;remoteFavoriteIds=new Set();localStorage.removeItem(SESSION);refreshHeader();render();notify('Вы вышли из аккаунта')}}))}
function authDialog(mode='login'){
  const signup=mode==='signup';
  const telegramClientId=String(window.KLB_SUPABASE_CONFIG?.telegramClientId||'').trim();
  const telegramRedirectUri=String(window.KLB_SUPABASE_CONFIG?.telegramRedirectUri||'').trim();
  const telegramEnabled=/^\d+$/.test(telegramClientId)&&/^https:\/\//i.test(telegramRedirectUri);
  const inTelegramMiniApp=!!(window.Telegram?.WebApp?.initData);
  const telegramBlock=telegramEnabled?'<div class="telegram-login-divider">или</div><div id="telegramLoginMount" class="telegram-login-mount"><button type="button" class="tg-auth-button">'+(inTelegramMiniApp?'Продолжить с Telegram':'Войти через Telegram')+'</button></div>':'';
  modal(signup?'Создать аккаунт':'Вход в KLB STORE',`<form id="authForm" class="modal-form">${signup?'<label>Никнейм / логин<input name="username" minlength="3" maxlength="24" required autocomplete="username" placeholder="Твой ник"></label>':'<label>Логин<input name="username" required autocomplete="username" placeholder="Логин"></label>'}<label>Пароль<input name="password" type="password" minlength="4" required autocomplete="current-password" placeholder="Пароль"></label>${signup?'<label>Повтор пароля<input name="confirm" type="password" minlength="4" required placeholder="Повтори пароль"></label>':''}<p class="form-error" id="authError"></p><button class="primary-action" type="submit">${signup?'Зарегистрироваться':'Войти'}</button><button class="link-action" type="button" id="switchAuth">${signup?'Уже есть аккаунт? Войти':'Нет аккаунта? Зарегистрироваться'}</button>${telegramBlock}</form>`);
  $('#authForm').addEventListener('submit',e=>{
    e.preventDefault();
    const fd=new FormData(e.target),username=(fd.get('username')||'').trim(),password=fd.get('password'),err=$('#authError');
    if(SB){sbAuth(signup,username,password,fd.get('confirm'),err);return}
    if(signup){
      if(username.length<3){err.textContent='Никнейм должен быть не короче 3 символов';return}
      if(password!==fd.get('confirm')){err.textContent='Пароли не совпадают';return}
      if(users.some(u=>u.username.toLowerCase()===username.toLowerCase())){err.textContent='Этот логин уже занят';return}
      const user={id:'u'+Date.now(),username,password,role:'user',joined:new Date().toISOString(),status:'Активен',sellerStatus:'Нет'};
      users.push(user);write(STORE,users);setCurrent(user);closeModal();notify('Аккаунт создан. Добро пожаловать!');
    }else{
      const user=users.find(u=>u.username.toLowerCase()===username.toLowerCase()&&u.password===password);
      if(!user){err.textContent='Неверный логин или пароль';return}
      if(user.status==='Заблокирован'){err.textContent='Аккаунт заблокирован администратором';return}
      setCurrent(user);closeModal();notify('Вход выполнен');
    }
  });
  $('#switchAuth').onclick=()=>authDialog(signup?'login':'signup');
  if(telegramEnabled&&$('#telegramLoginMount')){
    const button=$('#telegramLoginMount .tg-auth-button');
    button.onclick=async()=>{
      button.disabled=true;button.textContent='Переход в Telegram…';
      try{
        if(window.Telegram?.WebApp?.initData) await handleTelegramMiniAppStartup(true);
        else await beginTelegramOidcLogin(telegramClientId,telegramRedirectUri);
      }catch(error){button.disabled=false;button.textContent=window.Telegram?.WebApp?.initData?'Продолжить с Telegram':'Войти через Telegram';const mount=$('#telegramLoginMount');mount.insertAdjacentHTML('beforeend',`<small class=\"telegram-login-error\">${esc(error?.message||'Не удалось начать вход через Telegram.')}</small>`);}
    };
  }

}

function base64Url(bytes){
  let binary='';for(const b of bytes)binary+=String.fromCharCode(b);
  return btoa(binary).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}
function randomUrlSafe(length=32){const bytes=new Uint8Array(length);crypto.getRandomValues(bytes);return base64Url(bytes);}
async function beginTelegramOidcLogin(clientId,redirectUri){
  if(!window.isSecureContext||!crypto?.subtle)throw new Error('Для входа через Telegram нужен HTTPS.');
  if(!SB)throw new Error('Сначала подключи Supabase.');
  const state=randomUrlSafe(32);
  const verifier=randomUrlSafe(48);
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier));
  const challenge=base64Url(new Uint8Array(digest));
  sessionStorage.setItem('klb_telegram_oidc_pending',JSON.stringify({state,verifier,redirectUri,createdAt:Date.now()}));
  const params=new URLSearchParams({
    client_id:clientId,
    redirect_uri:redirectUri,
    response_type:'code',
    scope:'openid profile telegram:bot_access',
    state,
    code_challenge:challenge,
    code_challenge_method:'S256'
  });
  // Use Telegram's documented OIDC Authorization Code + PKCE flow.
  location.assign(`https://oauth.telegram.org/auth?${params.toString()}`);
}
async function handleTelegramOidcCallback(){
  const params=new URLSearchParams(location.search);
  const code=params.get('code');
  const oauthError=params.get('error');
  if(!code&&!oauthError)return false;
  const state=params.get('state');
  const savedRaw=sessionStorage.getItem('klb_telegram_oidc_pending');
  sessionStorage.removeItem('klb_telegram_oidc_pending');
  // Remove one-time authorization code from the address bar immediately.
  history.replaceState({},document.title,location.pathname+location.hash);
  if(oauthError)throw new Error(params.get('error_description')||oauthError);
  if(!savedRaw)throw new Error('Сессия входа Telegram не найдена. Начни вход заново.');
  let saved;try{saved=JSON.parse(savedRaw)}catch{throw new Error('Не удалось прочитать данные входа Telegram.');}
  if(!state||state!==saved.state)throw new Error('Проверка state не прошла. Начни вход через Telegram заново.');
  if(Date.now()-Number(saved.createdAt||0)>10*60*1000)throw new Error('Время входа Telegram истекло. Попробуй ещё раз.');
  if(!SB)throw new Error('Supabase не подключён.');
  const result=await SB.telegramLoginCode(code,saved.verifier,saved.redirectUri);
  await refreshProfile(true);
  if(!current)throw new Error('Telegram подтвердил вход, но профиль KLB STORE не загрузился. Проверь запись в profiles и права SELECT.');
  notify(result.is_new?'Аккаунт через Telegram создан!':'Вход через Telegram выполнен');
  if(sessionStorage.getItem(PENDING_CHAT))openPendingChatIfReady();
  if(result.is_new)promptTelegramPasswordSetup();
  return true;
}

function setupTelegramMiniAppUi(){
  const tg=window.Telegram?.WebApp;
  if(!tg)return;
  try{
    tg.ready();
    tg.expand();
    if(typeof tg.setHeaderColor==='function')tg.setHeaderColor('#080b12');
    if(typeof tg.setBackgroundColor==='function')tg.setBackgroundColor('#080b12');
    document.documentElement.classList.add('klb-telegram-miniapp');
    const applyViewport=()=>{
      const h=Number(tg.viewportStableHeight||tg.viewportHeight||0);
      if(h>0)document.documentElement.style.setProperty('--tg-viewport-stable-height',`${Math.round(h)}px`);
    };
    applyViewport();
    tg.onEvent?.('viewportChanged',applyViewport);
  }catch(e){console.warn('KLB Telegram WebApp UI setup:',e)}
}

function promptTelegramPasswordSetup(){
  modal('Задай пароль',`<p class="modal-lead">Аккаунт создан через Telegram. Придумай пароль, чтобы при желании входить на KLB STORE также по логину и паролю.</p><form id="telegramPasswordForm" class="modal-form"><label>Новый пароль<input name="password" type="password" minlength="6" required autocomplete="new-password"></label><label>Повтори пароль<input name="confirm" type="password" minlength="6" required autocomplete="new-password"></label><p class="form-error" id="telegramPasswordError"></p><button class="primary-action">Сохранить пароль</button><button type="button" class="link-action" id="skipTelegramPassword">Позже</button></form>`);
  $('#skipTelegramPassword').onclick=closeModal;
  $('#telegramPasswordForm').onsubmit=async e=>{
    e.preventDefault();const f=e.currentTarget;
    if(f.elements.password.value!==f.elements.confirm.value){$('#telegramPasswordError').textContent='Пароли не совпадают.';return;}
    const b=f.querySelector('button.primary-action');b.disabled=true;
    try{const {error}=await SB.client.auth.updateUser({password:f.elements.password.value});if(error)throw error;modal('Готово','<p class="modal-lead">Пароль сохранён. Теперь можно входить через Telegram или по логину и паролю.</p>');}
    catch(err){$('#telegramPasswordError').textContent=SB.ruError(err);b.disabled=false;}
  };
}

async function handleTelegramMiniAppStartup(force=false){
  const tg=window.Telegram?.WebApp;
  const initData=typeof tg?.initData==='string'?tg.initData:'';
  if(!tg||!initData)return false;
  setupTelegramMiniAppUi();
  if(!SB)throw new Error('KLB STORE не подключён к Supabase.');
  const session=await SB.session();
  if(session?.user){
    const linked=await SB.linkTelegramMiniApp(initData);
    window.KLB_TELEGRAM_LINKED_IN_MINIAPP=true;
    await refreshProfile(true);
    if(!current)throw new Error('Telegram привязан, но профиль KLB STORE не загрузился. Проверь запись в profiles и права SELECT.');
    notify(linked?.already_linked?'Telegram уже привязан к этому аккаунту.':'Telegram привязан к текущему аккаунту KLB STORE.');
  }else{
    const result=await SB.telegramMiniAppLogin(initData);
    await refreshProfile(true);
    if(!current)throw new Error('Telegram подтвердил пользователя, но профиль KLB STORE не загрузился. Проверь запись в profiles и права SELECT.');
    window.KLB_TELEGRAM_LINKED_IN_MINIAPP=true;
    notify(result.is_new?'Аккаунт KLB STORE создан через Telegram!':'Вход в KLB STORE через Telegram выполнен.');
    if(result.is_new)promptTelegramPasswordSetup();
  }
  await loadCatalog();
  if(sessionStorage.getItem(PENDING_CHAT))openPendingChatIfReady();
  return true;
}

async function refreshProfile(strict=false){
  if(!SB)return null;
  try{
    const p=await SB.profile();
    if(!p||p.status==='blocked'){
      if(p)await SB.logout();
      current=null;remoteFavoriteIds=new Set();walletBal=0;walletReserved=0;walletEscrow=0;refreshHeader();
      if(p?.status==='blocked'&&strict)throw new Error('Аккаунт KLB STORE заблокирован.');
      return null;
    }
    current={id:p.id,username:p.username,role:p.role,moderator_level:Number(p.moderator_level||0)};
    try{
      const legacyIds=read(FAV,{})[current.id]||[];
      remoteFavoriteIds=new Set(await SB.migrateLegacyFavoriteListingIds(legacyIds));
    }catch(favError){remoteFavoriteIds=new Set();console.warn('KLB favorites load failed:',favError)}
    await refreshWallet();
    render();
    return p;
  }catch(e){
    console.error('KLB profile hydration failed:',e);
    if(strict)throw e;
    return null;
  }
}
async function refreshWallet(){if(!SB||!current)return;try{const w=await SB.wallet();walletBal=w.available;walletReserved=w.reserved;walletEscrow=w.escrow||0}catch(e){console.error(e)}refreshHeader()}
async function sbAuth(signup,username,password,confirm,err){err.textContent='';const btn=document.querySelector('#authForm button[type=submit]');btn.disabled=true;try{if(signup){if(!/^[a-zA-Z0-9_]{3,24}$/.test(username))throw new Error('Логин: 3–24 символа, латиница, цифры и _');if(password.length<6)throw new Error('Пароль должен быть не короче 6 символов.');if(password!==confirm)throw new Error('Пароли не совпадают');await SB.register(username,password)}await SB.login(username,password);await refreshProfile();if(!current)throw new Error('Не удалось войти. Если аккаунт только что создан, отключи подтверждение email в настройках Supabase Auth.');closeModal();notify(signup?'Аккаунт создан. Добро пожаловать!':'Вход выполнен');if(sessionStorage.getItem(PENDING_CHAT))openPendingChatIfReady()}catch(e){err.textContent=SB.ruError(e);btn.disabled=false}}

function setCurrent(user){current={id:user.id,username:user.username,role:user.role};write(SESSION,current);refreshHeader()}
const BANKS=['Сбербанк','Т-Банк','ВТБ','Альфа-Банк','Газпромбанк','ПСБ','Совкомбанк','Россельхозбанк','Московский кредитный банк','Банк Санкт-Петербург','ОТП Банк','МТС Банк','Уралсиб','Почта Банк','Яндекс Банк','Банк ДОМ.РФ','Райффайзенбанк','ЮниКредит Банк','АК БАРС','Русский Стандарт','Озон Банк','Другой банк'];
const BANK_BRANDS={
  'Сбербанк':{mark:'S',tone:'sber'},'Т-Банк':{mark:'Т',tone:'tbank'},'ВТБ':{mark:'ВТБ',tone:'vtb'},'Альфа-Банк':{mark:'A',tone:'alfa'},'Газпромбанк':{mark:'Г',tone:'gaz'},'ПСБ':{mark:'ПСБ',tone:'psb'},'Совкомбанк':{mark:'С',tone:'sovkom'},'Россельхозбанк':{mark:'РСХБ',tone:'rshb'},'Московский кредитный банк':{mark:'МКБ',tone:'mkb'},'Банк Санкт-Петербург':{mark:'БСПБ',tone:'bspb'},'ОТП Банк':{mark:'OTP',tone:'otp'},'МТС Банк':{mark:'МТС',tone:'mts'},'Уралсиб':{mark:'U',tone:'uralsib'},'Почта Банк':{mark:'ПБ',tone:'pochta'},'Яндекс Банк':{mark:'Я',tone:'yandex'},'Банк ДОМ.РФ':{mark:'ДОМ',tone:'dom'},'Райффайзенбанк':{mark:'R',tone:'raiff'},'ЮниКредит Банк':{mark:'U',tone:'unicredit'},'АК БАРС':{mark:'АК',tone:'akbars'},'Русский Стандарт':{mark:'РС',tone:'rsb'},'Озон Банк':{mark:'O',tone:'ozon'},'Другой банк':{mark:'+',tone:'neutral'}
};
const walletKey='klb_wallets',depositKey='klb_deposits',withdrawKey='klb_withdrawals',walletSettingsKey='klb_wallet_settings';
function wallet(userId){if(SB)return walletBal;const w=read(walletKey,{});return Number(w[userId]||0)}
function setWallet(userId,value){const w=read(walletKey,{});w[userId]=Math.max(0,Number(value)||0);write(walletKey,w);if(current&&current.id===userId)refreshHeader()}
function walletHistory(userId){return read('klb_wallet_history',[]).filter(x=>x.userId===userId)}
function addLedger(userId,kind,amount,ref,note){const h=read('klb_wallet_history',[]);h.push({id:'W'+Date.now()+Math.random().toString(36).slice(2,6),userId,kind,amount:Number(amount),ref,note,date:new Date().toISOString()});write('klb_wallet_history',h)}
function walletDialog(){if(!current){authDialog('login');return}if(SB){refreshWallet().then(walletDialogView);return}walletDialogView()}
function walletDialogView(){modal('Кошелёк',`<div class="wallet-balance"><span>Доступный баланс</span><b>${wallet(current.id).toLocaleString('ru-RU')} ₽</b>${SB&&walletReserved>0?`<span style="margin-top:8px">В обработке (вывод): ${walletReserved.toLocaleString('ru-RU')} ₽</span>`:''}${SB&&walletEscrow>0?`<span style="margin-top:8px">Оплаченные заказы до подтверждения: ${walletEscrow.toLocaleString('ru-RU')} ₽</span>`:''}</div><div class="profile-menu"><button data-wallet="deposit">＋ Пополнить баланс</button><button data-wallet="withdraw">↗ Вывести средства</button><button data-wallet="history">◷ История операций</button><button data-wallet="chats">✉ Чаты и сделки</button></div>`);document.querySelectorAll('#appModal [data-wallet]').forEach(b=>b.addEventListener('click',()=>{const a=b.dataset.wallet;if(a==='deposit')depositDialog();if(a==='withdraw')withdrawDialog();if(a==='history')walletHistoryDialog();if(a==='chats')openChats()}))}
async function sbDepositDialog(){modal('Пополнение баланса','<div class="empty-modal">Загрузка…</div>');let ins;try{ins=await SB.depositInstructions()}catch(e){modal('Пополнение баланса',`<p class="form-error">${esc(SB.ruError(e))}</p>`);return}if(!ins.bank||!ins.details){modal('Пополнение баланса','<div class="empty-modal">Реквизиты для пополнения ещё не настроены администратором. Попробуй позже.</div>');return}modal('Пополнение баланса',`<form class="modal-form" id="depositForm"><label>Сумма, ₽<input name="amount" type="number" min="100" max="1000000" step="1" required placeholder="Например, 1000"></label><p class="modal-lead">После создания заявки переведи деньги на указанные реквизиты и обязательно укажи код в комментарии к переводу.</p><p><b>Банк:</b> ${esc(ins.bank)}<br><b>Реквизиты:</b> ${esc(ins.details)}</p><p class="form-error" id="depositError"></p><button class="primary-action">Создать заявку</button></form>`);$('#depositForm').onsubmit=async e=>{e.preventDefault();const amount=Number(new FormData(e.target).get('amount')),btn=e.target.querySelector('button');if(!(amount>=100&&amount<=1000000)){$('#depositError').textContent='Минимум 100 ₽, максимум 1 000 000 ₽';return}btn.disabled=true;try{const r=await SB.createDeposit(amount);modal('Заявка создана',`<div class="order-success"><span>✓</span><h3>Переведи ${amount.toLocaleString('ru-RU')} ₽</h3><p><b>${esc(ins.bank)}</b><br>${esc(ins.details)}</p><div class="wallet-code">${esc(r.comment_code)}</div><p class="modal-lead">Укажи этот код в комментарии к переводу. Начисление произойдёт после проверки администратором.</p><button class="primary-action" id="depositPaid">Я оплатил(а)</button><button class="secondary-action" id="depositDone">Закрыть</button></div>`);$('#depositDone').onclick=closeModal;$('#depositPaid').onclick=async()=>{try{await SB.markDepositChecking(r.id);closeModal();notify('Заявка передана на проверку')}catch(er){notify(SB.ruError(er))}}}catch(er){$('#depositError').textContent=SB.ruError(er);btn.disabled=false}}}
async function sbWithdraw(v){const btn=document.querySelector('#withdrawForm button[type=submit]');btn.disabled=true;try{await SB.createWithdrawal(v);await refreshWallet();closeModal();notify('Заявка на вывод отправлена')}catch(e){$('#withdrawError').textContent=SB.ruError(e);btn.disabled=false}}
async function sbHistory(){modal('История кошелька','<div class="empty-modal">Загрузка…</div>');try{const [led,deps,wds]=await Promise.all([SB.ledger(),SB.myDeposits(),SB.myWithdrawals()]);const L={deposit:'Пополнение',withdrawal_reserve:'Вывод: резерв',withdrawal_refund:'Вывод: возврат',withdrawal_paid:'Вывод: выплачено',purchase:'Покупка',purchase_escrow:'Оплата заказа удержана в эскроу',sale:'Продажа до комиссии',commission:'Комиссия KLB STORE · 5%',adjustment:'Корректировка'};const reqs=[...deps.map(d=>({t:d.created_at,title:'Заявка на пополнение · код '+d.comment_code,st:SB.labels.DEP[d.status]||d.status,amt:Number(d.amount)})),...wds.map(d=>({t:d.created_at,title:'Заявка на вывод',st:SB.labels.WDR[d.status]||d.status,amt:-Number(d.amount)}))].sort((a,b)=>b.t.localeCompare(a.t));const row=(title,sub,amt)=>`<article class="deal-row"><div><b>${esc(title)}</b><small>${esc(sub)}</small></div><div class="deal-price">${amt>0?'+':''}${amt.toLocaleString('ru-RU')} ₽</div></article>`;modal('История кошелька',(reqs.length?`<h3>Заявки</h3><div class="deal-list">${reqs.map(r=>row(r.title,new Date(r.t).toLocaleString('ru-RU')+' · '+r.st,r.amt)).join('')}</div>`:'')+(led.length?`<h3>Операции по балансу</h3><div class="deal-list">${led.map(x=>row(L[x.operation]||x.operation,new Date(x.created_at).toLocaleString('ru-RU'),Number(x.amount))).join('')}</div>`:'')||'<div class="empty-modal">Операций пока нет.</div>')}catch(e){modal('История кошелька',`<p class="form-error">${esc(SB.ruError(e))}</p>`)}}
function depositDialog(){if(SB){sbDepositDialog();return}const settings=read(walletSettingsKey,{}),bank=settings.depositBank||'Банк не настроен',card=settings.depositCard||'Реквизиты пока не указаны';modal('Пополнение баланса',`<form class="modal-form" id="depositForm"><label>Сумма, ₽<input name="amount" type="number" min="100" max="1000000" step="1" required placeholder="Например, 1000"></label><p class="modal-lead">После создания заявки переведи деньги на указанные реквизиты и обязательно укажи код в комментарии к переводу.</p><p><b>Банк:</b> ${esc(bank)}<br><b>Реквизиты:</b> ${esc(card)}</p><p class="form-error" id="depositError"></p><button class="primary-action">Создать заявку</button></form>`);$('#depositForm').onsubmit=e=>{e.preventDefault();const amount=Number(new FormData(e.target).get('amount'));if(amount<100||amount>1000000){$('#depositError').textContent='Минимум 100 ₽, максимум 1 000 000 ₽';return}let code;const all=read(depositKey,[]);do{code=String(Math.floor(10000+Math.random()*90000))}while(all.some(x=>x.code===code&&['Ожидает оплаты','Проверка'].includes(x.status)));const req={id:'D'+Date.now(),userId:current.id,username:current.username,amount,code,bank,card,status:'Ожидает оплаты',created:new Date().toISOString()};all.push(req);write(depositKey,all);modal('Заявка создана',`<div class="order-success"><span>✓</span><h3>Переведи ${amount.toLocaleString('ru-RU')} ₽</h3><p><b>${esc(bank)}</b><br>${esc(card)}</p><div class="wallet-code">${code}</div><p class="modal-lead">Укажи этот код в комментарии к переводу. Код уникален для заявки. Начисление произойдёт после проверки администратором.</p><button class="primary-action" id="depositDone">Понятно</button></div>`);$('#depositDone').onclick=closeModal}}
function withdrawDialog(){
  const bankBrand = (bank) => {
    const brand = BANK_BRANDS[bank] || { mark: 'Б', tone: 'neutral' };
    return `<span class="pay-brand pay-brand-${brand.tone}" aria-hidden="true">${esc(brand.mark)}</span>`;
  };
  const bankOptions = BANKS.map(bank => `<button type="button" class="bank-option${bank==='Сбербанк'?' is-selected':''}" role="option" aria-selected="${bank==='Сбербанк'?'true':'false'}" data-bank-option="${esc(bank)}">${bankBrand(bank)}<span class="bank-option-name">${esc(bank)}</span><span class="bank-option-check" aria-hidden="true">✓</span></button>`).join('');
  modal('Вывод средств', `
    <form class="modal-form withdraw-form" id="withdrawForm">
      <div class="withdraw-section-label">Способ вывода</div>
      <div class="withdraw-method-grid" role="radiogroup" aria-label="Способ вывода">
        <button type="button" class="withdraw-method-card is-active" data-method-option="bank" role="radio" aria-checked="true">
          <span class="withdraw-method-icon method-card-icon" aria-hidden="true"><svg viewBox="0 0 32 32"><rect x="4" y="7" width="24" height="18" rx="4"/><path d="M4 13h24M9 20h6"/></svg></span>
          <span class="withdraw-method-copy"><b>На карту банка</b><small>Перевод по номеру телефона</small></span>
          <span class="withdraw-method-check" aria-hidden="true">✓</span>
        </button>
        <button type="button" class="withdraw-method-card" data-method-option="sbp" role="radio" aria-checked="false">
          <span class="withdraw-method-icon method-sbp-icon" aria-hidden="true"><svg viewBox="0 0 32 32"><path d="M7 11h16l-4-4M25 21H9l4 4M23 11l3 3-3 3M9 21l-3-3 3-3"/></svg></span>
          <span class="withdraw-method-copy"><b>Перевод по СБП</b><small>Моментальный перевод по телефону</small></span>
          <span class="withdraw-method-check" aria-hidden="true">✓</span>
        </button>
        <button type="button" class="withdraw-method-card" data-method-option="usdt" role="radio" aria-checked="false">
          <span class="withdraw-method-icon method-usdt-icon" aria-hidden="true">₮</span>
          <span class="withdraw-method-copy"><b>USDT TRC20</b><small>Криптовалютный перевод в сети TRON</small></span>
          <span class="withdraw-method-check" aria-hidden="true">✓</span>
        </button>
      </div>
      <input type="hidden" name="method" value="bank">

      <div class="withdraw-bank-fields" id="withdrawFields">
        <label><span id="bankFieldLabel">Банк получателя</span>
          <div class="bank-picker" id="withdrawBankPicker">
            <button type="button" class="bank-picker-trigger" id="bankPickerTrigger" aria-expanded="false" aria-controls="bankPickerMenu">
              ${bankBrand('Сбербанк')}
              <span class="bank-picker-selected"><b id="selectedBankName">Сбербанк</b><small>Выбери банк для получения средств</small></span>
              <svg class="bank-picker-chevron" viewBox="0 0 20 20" aria-hidden="true"><path d="m5 7 5 5 5-5"/></svg>
            </button>
            <div class="bank-picker-menu" id="bankPickerMenu" hidden>
              <div class="bank-picker-search"><svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="8.5" cy="8.5" r="5.5"/><path d="m13 13 4 4"/></svg><input type="search" id="bankSearch" placeholder="Найти банк…" autocomplete="off" aria-label="Найти банк"></div>
              <div class="bank-picker-options" role="listbox" aria-label="Список банков">${bankOptions}</div>
            </div>
            <input type="hidden" name="bank" value="Сбербанк">
          </div>
        </label>
        <label><span id="phoneFieldLabel">Номер телефона получателя</span><input name="phone" type="tel" inputmode="tel" autocomplete="tel" placeholder="+7 900 000-00-00"></label>
      </div>
      <label id="cryptoField" class="withdraw-crypto-field" hidden>Адрес USDT TRC20<input name="address" placeholder="T..." autocomplete="off" spellcheck="false"></label>
      <label>Сумма в рублях<input name="amount" type="number" min="500" step="1" required inputmode="numeric" placeholder="Минимум 500"></label>
      <div class="withdraw-balance-note"><span class="withdraw-note-icon" aria-hidden="true">i</span><span>Доступно: <b>${wallet(current.id).toLocaleString('ru-RU')} ₽</b>. Минимальная сумма вывода — 500 ₽. Заявка будет проверена администратором. Для USDT сумма указывается в рублёвом эквиваленте; выплата производится вручную в сети TRC20.</span></div>
      <p class="form-error" id="withdrawError"></p>
      <button type="submit" class="primary-action withdraw-submit">Отправить заявку</button>
    </form>`);

  const f = $('#withdrawForm');
  const methodInput = f.elements.method;
  const bankFields = $('#withdrawFields');
  const cryptoField = $('#cryptoField');
  const phoneInput = f.elements.phone;
  const addressInput = f.elements.address;
  const bankPicker = $('#withdrawBankPicker');
  const bankTrigger = $('#bankPickerTrigger');
  const bankMenu = $('#bankPickerMenu');
  const bankSearch = $('#bankSearch');
  const bankHidden = f.elements.bank;

  const setMethod = (value) => {
    methodInput.value = value;
    f.querySelectorAll('[data-method-option]').forEach(button => {
      const active = button.dataset.methodOption === value;
      button.classList.toggle('is-active', active);
      button.setAttribute('aria-checked', active ? 'true' : 'false');
    });
    const isCrypto = value === 'usdt';
    bankFields.hidden = isCrypto;
    cryptoField.hidden = !isCrypto;
    phoneInput.required = !isCrypto;
    addressInput.required = isCrypto;
    $('#phoneFieldLabel').textContent = value === 'sbp' ? 'Номер телефона для СБП' : 'Номер телефона получателя';
  };
  f.querySelectorAll('[data-method-option]').forEach(button => button.addEventListener('click', () => setMethod(button.dataset.methodOption)));

  const openBankMenu = () => {
    bankMenu.hidden = false;
    bankTrigger.setAttribute('aria-expanded', 'true');
    bankSearch.value = '';
    bankMenu.querySelectorAll('[data-bank-option]').forEach(option => option.hidden = false);
    setTimeout(() => bankSearch.focus({ preventScroll: true }), 30);
  };
  const closeBankMenu = () => {
    bankMenu.hidden = true;
    bankTrigger.setAttribute('aria-expanded', 'false');
  };
  bankTrigger.addEventListener('click', () => bankMenu.hidden ? openBankMenu() : closeBankMenu());
  bankSearch.addEventListener('input', () => {
    const query = bankSearch.value.trim().toLocaleLowerCase('ru-RU');
    bankMenu.querySelectorAll('[data-bank-option]').forEach(option => {
      option.hidden = !option.dataset.bankOption.toLocaleLowerCase('ru-RU').includes(query);
    });
  });
  bankMenu.querySelectorAll('[data-bank-option]').forEach(option => option.addEventListener('click', () => {
    const bank = option.dataset.bankOption;
    bankHidden.value = bank;
    $('#selectedBankName').textContent = bank;
    const logo = bankPicker.querySelector('.bank-picker-trigger .pay-brand');
    logo.outerHTML = bankBrand(bank);
    bankMenu.querySelectorAll('[data-bank-option]').forEach(item => {
      const selected = item === option;
      item.classList.toggle('is-selected', selected);
      item.setAttribute('aria-selected', selected ? 'true' : 'false');
    });
    closeBankMenu();
  }));
  f.addEventListener('click', event => {
    if (!bankPicker.contains(event.target) && !bankMenu.hidden) closeBankMenu();
  });
  f.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !bankMenu.hidden) {
      event.preventDefault();
      closeBankMenu();
      bankTrigger.focus();
    }
  });

  setMethod('bank');
  f.onsubmit = e => {
    e.preventDefault();
    const fd = new FormData(f);
    const method = String(fd.get('method'));
    const amount = Number(fd.get('amount'));
    const balance = wallet(current.id);
    const bank = String(fd.get('bank') || '');
    const phone = String(fd.get('phone') || '').trim();
    const address = String(fd.get('address') || '').trim();
    const error = $('#withdrawError');
    error.textContent = '';

    if (!Number.isFinite(amount) || amount < 500) { error.textContent = 'Минимальная сумма вывода 500 ₽'; return; }
    if (amount > balance) { error.textContent = 'Недостаточно средств'; return; }
    if (method !== 'usdt' && (!bank || !/^\+?[0-9 ()-]{10,18}$/.test(phone))) { error.textContent = 'Укажи банк и корректный номер телефона'; return; }
    if (method === 'usdt' && !/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(address)) { error.textContent = 'Проверь адрес TRC20'; return; }

    const payload = { method, amount, bank, phone, address };
    if (SB) { sbWithdraw(payload); return; }
    setWallet(current.id, balance - amount);
    addLedger(current.id, 'withdrawal_reserve', -amount, 'pending', 'Средства зарезервированы для вывода');
    const req = { id: 'R' + Date.now(), userId: current.id, username: current.username, method, bank, phone, address, amount, status: 'Ожидает выплаты', created: new Date().toISOString() };
    const requests = read(withdrawKey, []);
    requests.push(req);
    write(withdrawKey, requests);
    closeModal();
    notify('Заявка на вывод отправлена');
  };
}
function walletHistoryDialog(){if(SB){sbHistory();return}const h=walletHistory(current.id).slice().reverse();modal('История кошелька',h.length?`<div class="deal-list">${h.map(x=>`<article class="deal-row"><div><b>${esc(x.note||x.kind)}</b><small>${new Date(x.date).toLocaleString('ru-RU')} · ${esc(x.ref||'')}</small></div><div class="deal-price">${x.amount>0?'+':''}${Number(x.amount).toLocaleString('ru-RU')} ₽</div></article>`).join('')}</div>`:'<div class="empty-modal">Операций пока нет.</div>')}
const sbListing=r=>({id:r.id,title:r.title,description:r.description,category:r.category,catalog_category:r.catalog_category||'other',catalog_subcategory:r.catalog_subcategory||'other',price:Number(r.price),stock:r.stock,image:r.image_url||'',status:SB.labels.LST[r.status]||r.status,note:r.moderation_note});
function sellerDashboard(){if(SB){SB.myListings().then(rows=>sellerDashboardView(rows.map(sbListing))).catch(e=>notify(SB.ruError(e)));return}sellerDashboardView(read(LISTINGS,[]).filter(p=>p.userId===current.id))}
function sellerDashboardView(items){
  const storeAdmin=current?.role==='admin';
  modal(storeAdmin?'Объявления KLB STORE':'Панель продавца',`<div class="wallet-balance"><span>${storeAdmin?'Объявления магазина':'Мои объявления'}</span><b>${items.length}</b></div><p class="modal-lead">${storeAdmin?'Новые объявления будут размещены от имени KLB STORE и отправлены на модерацию.':'Управляй своими товарами. Одобренное объявление можно продвинуть в топ выбранной категории за 49 ₽.'}</p><button class="primary-action" id="createListing">＋ ${storeAdmin?'Создать объявление от имени KLB STORE':'Создать объявление'}</button>${items.length?`<div class="deal-list">${items.map(p=>`<article class="deal-row seller-listing-row"><div><b>${esc(p.title)}</b><small>${esc(p.status)} · ${Number(p.price).toLocaleString('ru-RU')} ₽ · ${esc(categoryForSlug(p.catalog_category).name)} / ${esc(catalogSubcategoryName(p.catalog_category,p.catalog_subcategory))}${p.note?' · '+esc(p.note):''}</small></div><div class="seller-listing-actions"><button class="text-btn" data-seller-edit="${p.id}">Редактировать</button>${SB&&p.status==='Активно'&&!storeAdmin?`<button class="promote-listing-btn" data-seller-promote="${p.id}">Продвинуть за 49 ₽</button>`:''}${SB&&p.status==='Активно'?`<button class="text-btn" data-seller-pause="${p.id}">Снять с продажи</button>`:''}${SB&&p.status==='Приостановлено'?`<button class="text-btn" data-seller-resume="${p.id}">Вернуть на проверку</button>`:''}</div></article>`).join('')}</div>`:'<div class="empty-modal">Объявлений пока нет.</div>'}`);
  $('#createListing').onclick=()=>listingForm();
  document.querySelectorAll('#appModal [data-seller-edit]').forEach(b=>b.addEventListener('click',()=>{const item=items.find(p=>String(p.id)===b.dataset.sellerEdit);if(item)listingForm(item)}));
  document.querySelectorAll('#appModal [data-seller-promote]').forEach(b=>b.addEventListener('click',async()=>{b.disabled=true;try{const result=await SB.promoteListing(b.dataset.sellerPromote);await refreshWallet();notify(`Объявление продвинуто! Списано ${Number(result.amount||49).toLocaleString('ru-RU')} ₽.`);await sellerDashboard()}catch(e){notify(SB.ruError(e));b.disabled=false}}));
  document.querySelectorAll('#appModal [data-seller-pause],#appModal [data-seller-resume]').forEach(b=>b.addEventListener('click',async()=>{try{await SB.updateListing(b.dataset.sellerPause||b.dataset.sellerResume,{status:b.dataset.sellerPause?'paused':'pending'});notify(b.dataset.sellerPause?'Объявление снято с продажи':'Объявление отправлено на проверку');sellerDashboard()}catch(e){notify(SB.ruError(e))}}));
}
async function sbSaveListing(edit,item,v,file){const btn=document.querySelector('#listingForm button');btn.disabled=true;try{if(file){if(file.size>1500000){notify('Изображение слишком большое. Максимум 1,5 МБ');btn.disabled=false;return}v.image_url=await SB.uploadImage(file)}if(edit)await SB.updateListing(item.id,v);else await SB.createListing(v);closeModal();notify(current?.role==='admin'?'Объявление KLB STORE отправлено на модерацию':'Объявление отправлено на модерацию')}catch(e){notify(SB.ruError(e));btn.disabled=false}}
function listingForm(item=null){
  const edit=!!item,storeAdmin=current?.role==='admin';
  const rootSlug=item?.catalog_category||'other';
  const subSlug=item?.catalog_subcategory||'other';
  const rootOptions=KLB_CATALOG_CATEGORIES.map(c=>`<option value="${c.slug}" ${rootSlug===c.slug?'selected':''}>${esc(c.name)}</option>`).join('');
  const subOptions=categoryForSlug(rootSlug).subs.map(([slug,label])=>`<option value="${slug}" ${subSlug===slug?'selected':''}>${esc(label)}</option>`).join('');
  modal(edit?'Редактирование объявления':(storeAdmin?'Новое объявление KLB STORE':'Новое объявление'),`${storeAdmin?'<p class="modal-lead">Публикация от имени магазина KLB STORE.</p>':''}<form id="listingForm" class="modal-form"><label>Название<input name="title" maxlength="100" required value="${esc(item?.title||'')}"></label><label>Изображение карточки<input name="image" type="file" accept="image/*"></label><label>Описание<textarea name="description" rows="5" maxlength="3000" required>${esc(item?.description||'')}</textarea></label><label>Категория / игра<select name="catalog_category" id="listingRootCategory" required>${rootOptions}</select></label><label>Подкатегория<select name="catalog_subcategory" id="listingSubcategory" required>${subOptions}</select></label><label>Цена, ₽<input name="price" type="number" min="1" step="1" required value="${esc(item?.price||'')}"></label><label>Количество<input name="stock" type="number" min="1" max="999" required value="${esc(item?.stock||1)}"></label><p class="modal-lead">Объявление попадёт в выбранную категорию и подкатегорию после одобрения администрацией. ${storeAdmin?'В каталоге продавцом будет указано KLB STORE.':'После одобрения можно продвинуть объявление в топ категории за 49 ₽.'}</p><button class="primary-action">${edit?'Сохранить и отправить на проверку':'Отправить на модерацию'}</button></form>`);
  const rootSelect=$('#listingRootCategory'),subSelect=$('#listingSubcategory');
  rootSelect.addEventListener('change',()=>{const cat=categoryForSlug(rootSelect.value);subSelect.innerHTML=cat.subs.map(([slug,label])=>`<option value="${slug}">${esc(label)}</option>`).join('')});
  $('#listingForm').onsubmit=e=>{e.preventDefault();const f=e.target,fd=new FormData(f),price=Number(fd.get('price')),root=String(fd.get('catalog_category')),sub=String(fd.get('catalog_subcategory'));if(price<=0)return;const category=legacyListingKind(sub);const finish=image=>{const arr=read(LISTINGS,[]);if(edit){const ix=arr.findIndex(p=>String(p.id)===String(item.id));if(ix>=0)arr[ix]={...arr[ix],title:fd.get('title').trim(),description:fd.get('description').trim(),category,catalog_category:root,catalog_subcategory:sub,price,stock:Number(fd.get('stock')),image,status:'На проверке'}}else arr.push({id:'P'+Date.now(),userId:current.id,seller:current.username,title:fd.get('title').trim(),description:fd.get('description').trim(),category,catalog_category:root,catalog_subcategory:sub,price,stock:Number(fd.get('stock')),image,status:'На проверке',created:new Date().toISOString()});write(LISTINGS,arr);closeModal();notify('Объявление отправлено на модерацию')};const file=f.elements.image.files[0];if(SB){sbSaveListing(edit,item,{title:fd.get('title').trim(),description:fd.get('description').trim(),category,catalog_category:root,catalog_subcategory:sub,price,stock:Number(fd.get('stock'))},file);return}if(file){if(file.size>1500000){notify('Изображение слишком большое. Максимум 1,5 МБ');return}const r=new FileReader();r.onload=()=>finish(r.result);r.readAsDataURL(file)}else finish(item?.image||'')};
}
function openPromoActivationDialog(){
  modal('Активировать промокод',`<p class="modal-lead">Введи промокод, который создала администрация KLB STORE. После активации скидка применится к следующей покупке с баланса.</p><form id="marketplacePromoForm" class="modal-form"><label>Промокод<input name="code" maxlength=32 minlength=3 pattern="[A-Za-z0-9_-]{3,32}" autocomplete="off" required placeholder="Например, KLB10" style="text-transform:uppercase"></label><p class="form-error" id="marketplacePromoError"></p><button class="primary-action" type="submit">Активировать</button></form><p class="modal-lead">Один активный промокод на аккаунт. Он будет использован один раз при следующей успешной оплате. Один и тот же код нельзя применить повторно на этом аккаунте.</p>`);
  $('#marketplacePromoForm').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,button=form.querySelector('button'),code=form.elements.code.value.trim().toUpperCase();button.disabled=true;try{const result=await SB.activateMarketplacePromo(code);notify(`Промокод ${result.code} активирован!`);await showProfile()}catch(err){$('#marketplacePromoError').textContent=SB.ruError(err);button.disabled=false}};
}

async function showProfile(){
  if(!current)return;
  if(!SB){
    const orders=read(ORDERS,[]).filter(o=>o.buyerId===current.id),done=orders.filter(o=>o.status==='Завершён'),spent=done.reduce((n,o)=>n+Number(o.price||0),0),seller=read(SELLERS,[]).find(s=>s.userId===current.id);
    modal('Мой профиль',`<div class="funpay-profile-shell"><div class="profile-card"><div class="profile-avatar-large">${esc(current.username[0].toUpperCase())}</div><div><h3>${esc(current.username)}</h3><span class="profile-role">${current.role==='admin'?'Администратор':current.role==='seller'?'Продавец':current.moderator_level?'Модератор':'Пользователь'}</span></div></div><div class="profile-stats"><div><b>${orders.length}</b><span>Всего сделок</span></div><div><b>${done.length}</b><span>Завершено</span></div><div><b>${spent.toLocaleString('ru-RU')} ₽</b><span>Покупки</span></div></div><p>${esc(seller?.description||'Описание профиля пока не заполнено.')}</p><div class="modal-actions"><button class="primary-action" id="profileDeals">Мои сделки</button></div>`);
    $('#profileDeals').onclick=showDeals;return;
  }
  try{
    const data=await SB.profileDetails(current.id),p=data.profile,st=data.stats||{};
    const activePromo=await SB.myActiveMarketplacePromo();
    modal('Мой профиль',`<div class="funpay-profile-shell"><div class="profile-card"><div class="profile-avatar-large">${esc((p.username||'?')[0].toUpperCase())}</div><div><h3>${esc(p.username)}</h3><span class="profile-role">${p.role==='admin'?'Администратор':p.role==='seller'?'Продавец':Number(p.moderator_level||0)>0?'Модератор':'Пользователь'}</span></div></div><form id="profileUsernameForm" class="profile-username-form"><label>Никнейм и логин<input name="username" minlength="3" maxlength="24" pattern="[A-Za-z0-9_]{3,24}" required value="${esc(p.username)}"></label><button class="secondary-action" type="submit">Изменить ник и логин</button><small>После сохранения вход по старому нику перестанет работать.</small></form><div class="profile-stats"><div><b>${Number(st.completed_purchases||0)}</b><span>Покупки завершены</span></div><div><b>${Number(st.completed_sales||0)}</b><span>Продажи завершены</span></div><div><b>${Number(st.average_rating||0).toFixed(2)} ★</b><span>Рейтинг · ${Number(st.reviews_count||0)} отзывов</span></div></div><form id="profileBioForm" class="modal-form"><label>О себе / описание профиля<textarea name="bio" maxlength="1000" rows="4" placeholder="Расскажи о себе, товарах или услугах">${esc(p.bio||'')}</textarea></label><p class="form-error" id="profileBioError"></p><button class="primary-action" type="submit">Сохранить описание</button></form><section class="profile-promo-card"><div><b>Промокоды KLB STORE</b><p>Активируй код здесь — скидка автоматически применится к следующей покупке с баланса.</p></div>${activePromo?`<div class="profile-promo-active">Активирован: <b>${esc(activePromo.code)}</b> · ${activePromo.discount_type==='percent'?`${Number(activePromo.discount_value)}%`:`${Number(activePromo.discount_value).toLocaleString('ru-RU')} ₽`} скидки</div>`:'<div class="profile-promo-inactive">Промокод пока не активирован</div>'}<div class="profile-promo-actions"><button class="secondary-action" id="profilePromoActivate">${activePromo?'Заменить промокод':'Активировать промокод'}</button>${activePromo?'<button class="text-btn" id="profilePromoDeactivate">Снять промокод</button>':''}</div></section><div class="profile-details"><p><b>На KLB STORE с:</b> ${new Date(p.created_at).toLocaleDateString('ru-RU')}</p><p><b>Статус:</b> ${p.status==='blocked'?'Заблокирован':'Активен'}</p><p><b>Доступный баланс:</b> ${wallet(current.id).toLocaleString('ru-RU')} ₽</p><button class="secondary-action" id="profileWalletOpen">Управление балансом</button><button class="secondary-action" id="profileTelegramConnect">${window.KLB_TELEGRAM_LINKED_IN_MINIAPP?'Telegram подключён':'Привязать Telegram'}</button></div><h3 class="section-subtitle">Последние отзывы</h3>${data.reviews.length?`<div class="review-list">${data.reviews.slice(0,5).map(r=>`<article class="review-item"><b>${esc(r.reviewer)} · ${'★'.repeat(Number(r.rating))}${'☆'.repeat(5-Number(r.rating))}</b><p>${esc(r.comment||'Без комментария')}</p><small>${new Date(r.created_at).toLocaleDateString('ru-RU')}</small></article>`).join('')}</div>`:'<p class="modal-lead">Отзывов пока нет.</p>'}<div class="modal-actions"><button class="primary-action" id="profileDeals">Мои сделки</button><button class="secondary-action" id="profileWallet">Кошелёк</button>${current.role==='seller'?'<button class="secondary-action" id="profileSeller">Панель продавца</button>':''}${current.role==='admin'?'<button class="secondary-action" id="profileStore">Объявления KLB STORE</button>':''}${(current.role==='admin'||Number(current.moderator_level||0)>0)?'<button class="secondary-action" id="profileAdmin">Админ-панель</button>':''}</div></div>`);
    $('#profileUsernameForm').onsubmit=async e=>{e.preventDefault();const field=e.currentTarget.elements.username,button=e.currentTarget.querySelector('button'),name=field.value.trim();button.disabled=true;try{await SB.updateMyUsername(name);current.username=name;refreshHeader();notify('Никнейм и логин изменены');await showProfile()}catch(err){notify(SB.ruError(err));button.disabled=false}};
    $('#profileTelegramConnect').onclick=async()=>{if(window.KLB_TELEGRAM_LINKED_IN_MINIAPP){notify('Telegram подключён к этому аккаунту.');return}try{const code=await SB.createTelegramLinkCode(),bot=(window.KLB_SUPABASE_CONFIG?.telegramBotUsername||'').replace(/^@/,'' );if(!bot||bot==='YOUR_BOT_USERNAME'){modal('Привязка Telegram',`<p class="modal-lead">Сначала укажи публичный username бота в supabase-config.js.</p><p>Код для привязки: <b>${esc(code)}</b></p>`);return}const link=`https://t.me/${bot}?start=${encodeURIComponent(code)}`;modal('Привязка Telegram',`<p class="modal-lead">Открой бота и нажми Start. После этого бот сможет присылать уведомления о новых заказах.</p><a class="primary-action telegram-connect-link" href="${link}" target="_blank" rel="noopener">Открыть Telegram-бота</a><p>Код действует 15 минут.</p>`)}catch(err){notify(SB.ruError(err))}};
    $('#profileBioForm').onsubmit=async e=>{e.preventDefault();const field=e.currentTarget.elements.bio,btn=e.currentTarget.querySelector('button');btn.disabled=true;try{await SB.updateMyBio(field.value);notify('Описание профиля сохранено');await showProfile()}catch(err){$('#profileBioError').textContent=SB.ruError(err);btn.disabled=false}};
    $('#profilePromoActivate').onclick=openPromoActivationDialog;
    if($('#profilePromoDeactivate'))$('#profilePromoDeactivate').onclick=async()=>{const b=$('#profilePromoDeactivate');b.disabled=true;try{await SB.deactivateMarketplacePromo();notify('Промокод снят');await showProfile()}catch(err){notify(SB.ruError(err));b.disabled=false}};
    $('#profileDeals').onclick=showDeals;$('#profileWallet').onclick=walletDialog;$('#profileWalletOpen').onclick=walletDialog;$('#profileSeller')?.addEventListener('click',sellerDashboard);$('#profileStore')?.addEventListener('click',sellerDashboard);if($('#profileAdmin'))$('#profileAdmin').onclick=()=>location.href='admin-login.html';
  }catch(e){modal('Мой профиль',`<p class="form-error">${esc(SB.ruError(e))}</p>`)}
}
async function showPublicProfile(userId,chatId=null){
  if(!SB||!userId)return;
  try{
    const data=await SB.profileDetails(userId),p=data.profile,st=data.stats||{};
    modal('Профиль пользователя',`<div class="funpay-profile-shell public-profile-shell"><div class="profile-card"><div class="profile-avatar-large">${esc((p.username||'?')[0].toUpperCase())}</div><div><h3>${esc(p.username)}</h3><span class="profile-role">${p.role==='admin'?'Администратор':p.role==='seller'?'Продавец':Number(p.moderator_level||0)>0?'Модератор':'Покупатель'}</span></div></div><div class="profile-stats"><div><b>${Number(st.completed_purchases||0)}</b><span>Покупки</span></div><div><b>${Number(st.completed_sales||0)}</b><span>Продажи</span></div><div><b>${Number(st.average_rating||0).toFixed(2)} ★</b><span>Рейтинг · ${Number(st.reviews_count||0)}</span></div></div><section class="profile-public-bio"><b>Описание</b><p>${esc(p.bio||'Пользователь пока не добавил описание.')}</p></section><p class="modal-lead">На KLB STORE с ${new Date(p.created_at).toLocaleDateString('ru-RU')}</p><h3 class="section-subtitle">Отзывы о продавце</h3>${data.reviews.length?`<div class="review-list">${data.reviews.map(r=>`<article class="review-item"><b>${esc(r.reviewer)} · ${'★'.repeat(Number(r.rating))}${'☆'.repeat(5-Number(r.rating))}</b><p>${esc(r.comment||'Без комментария')}</p><small>${new Date(r.created_at).toLocaleDateString('ru-RU')}</small></article>`).join('')}</div>`:'<p class="modal-lead">Отзывы пока не оставляли.</p>'}<div class="modal-actions">${current&&current.id!==userId?'<button class="primary-action" id="publicProfileReport">Пожаловаться на пользователя</button>':''}${chatId?'<button class="secondary-action" id="publicProfileBack">Вернуться в чат</button>':''}</div></div>`);
    if($('#publicProfileReport'))$('#publicProfileReport').onclick=()=>openAccountReport(userId,p.username,chatId);
    if($('#publicProfileBack'))$('#publicProfileBack').onclick=()=>openChats(chatId);
  }catch(e){modal('Профиль пользователя',`<p class="form-error">${esc(SB.ruError(e))}</p>`)}
}
function openAccountReport(targetUserId,targetUsername,chatId=null){
  modal('Жалоба на пользователя',`<p class="modal-lead">Жалоба на <b>${esc(targetUsername||'пользователя')}</b> попадёт администрации KLB STORE. Опиши нарушение и приложи скриншот, если он есть.</p><form id="accountReportForm" class="modal-form"><label>Описание жалобы<textarea name="description" minlength="10" maxlength="2000" rows="5" required placeholder="Что произошло? Укажи подробности."></textarea></label><label>Скриншот (PNG, JPG или WEBP, до 5 МБ)<input name="evidence" type="file" accept="image/png,image/jpeg,image/webp"></label><p class="form-error" id="accountReportError"></p><button class="primary-action" type="submit">Отправить жалобу</button></form>`);
  $('#accountReportForm').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,btn=form.querySelector('button'),err=$('#accountReportError');btn.disabled=true;try{let path=null;const file=form.elements.evidence.files[0];if(file)path=await SB.uploadModerationEvidence(file);await SB.createAccountReport(targetUserId,form.elements.description.value,path,chatId);notify('Жалоба отправлена администрации');if(chatId)await openChats(chatId);else modal('Жалоба отправлена','<p class="modal-lead">Спасибо. Администрация рассмотрит обращение.</p>')}catch(ex){err.textContent=SB.ruError(ex);btn.disabled=false}};
}
function openReviewDialog(orderId,chatId){
  modal('Оставить отзыв',`<p class="modal-lead">Оцени продавца после получения товара или выполнения услуги.</p><form id="marketplaceReviewForm" class="modal-form"><label>Оценка<select name="rating" required><option value="5">5 — Отлично</option><option value="4">4 — Хорошо</option><option value="3">3 — Нормально</option><option value="2">2 — Плохо</option><option value="1">1 — Очень плохо</option></select></label><label>Комментарий<textarea name="comment" rows="4" maxlength="1500" placeholder="Поделись впечатлениями (необязательно)"></textarea></label><p class="form-error" id="reviewError"></p><button class="primary-action" type="submit">Опубликовать отзыв</button></form>`);
  $('#marketplaceReviewForm').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,btn=form.querySelector('button');btn.disabled=true;try{await SB.createReview(orderId,Number(form.elements.rating.value),form.elements.comment.value);notify('Спасибо за отзыв!');await openChats(chatId)}catch(ex){$('#reviewError').textContent=SB.ruError(ex);btn.disabled=false}};
}
function openDisputeDialog(orderId,chatId){
  modal('Оспорить заказ',`<p class="modal-lead">Опиши проблему с товаром, ключом, аккаунтом или услугой. Оплата останется в удержании либо будет возвращена по решению администрации.</p><form id="marketplaceDisputeForm" class="modal-form"><label>Причина спора<textarea name="reason" minlength="10" maxlength="2000" rows="5" required placeholder="Что именно не было передано или выполнено?"></textarea></label><label>Скриншот / доказательство (PNG, JPG или WEBP, до 5 МБ)<input name="evidence" type="file" accept="image/png,image/jpeg,image/webp"></label><p class="form-error" id="disputeError"></p><button class="primary-action" type="submit">Открыть спор</button></form>`);
  $('#marketplaceDisputeForm').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,btn=form.querySelector('button');btn.disabled=true;try{let path=null;const file=form.elements.evidence.files[0];if(file)path=await SB.uploadModerationEvidence(file);await SB.createDispute(orderId,form.elements.reason.value,path);notify('Спор отправлен администрации');await openChats(chatId)}catch(ex){$('#disputeError').textContent=SB.ruError(ex);btn.disabled=false}};
}
function showDeals(){const orders=read(ORDERS,[]).filter(o=>o.buyerId===current.id);modal('Мои сделки',orders.length?`<div class="deal-list">${orders.map(o=>`<article class="deal-row"><div><b>${esc(o.product)}</b><small>Заказ ${esc(o.id)} · ${esc(o.created||'')}</small></div><div class="deal-price">${Number(o.price).toLocaleString('ru-RU')} ₽<small>${esc(o.status)}</small></div></article>`).join('')}</div>`:'<div class="empty-modal">Пока сделок нет. Выбери товар в каталоге, чтобы создать тестовый заказ.</div>')}
async function showFavorites(){
  if(!current){authDialog('signup');return}
  modal('Избранное','<div id="favoritesContent" class="empty-modal">Загружаем избранное…</div>');
  try{
    let items=[];
    if(SB){
      items=await SB.myFavoriteListings();
      remoteFavoriteIds=new Set(items.map(item=>String(item.id)));
    }else{
      const ids=read(FAV,{})[current.id]||[];
      items=products.filter(item=>ids.includes(String(item.id)));
    }
    const host=$('#favoritesContent');
    if(!host)return;
    if(!items.length){host.className='empty-modal';host.textContent='В избранном пока пусто. Нажми ♡ на карточке понравившегося товара.';return}
    host.className='favorites-content';
    host.innerHTML=`<p class="favorites-count">Товары в избранном: <b>${items.length}</b></p><div class="product-grid favorites-grid">${items.map(item=>{
      const title=item.title||'Товар';
      const description=item.description||item.desc||'Цифровой товар';
      const image=item.image_url||item.image||'';
      const seller=item.seller||'';
      return `<article class="product-card"><div class="product-image"><span class="product-label">KLB</span>${image?`<img src="${esc(image)}" alt="${esc(title)}" loading="lazy">`:'<span class="placeholder-symbol">✦</span>'}</div><div class="product-info"><h3>${esc(title)}</h3><p>${esc(description)}</p>${seller?`<small class="product-seller">${seller==='KLB STORE'?'Магазин KLB STORE':`Продавец: ${esc(seller)}`}</small>`:''}<div class="product-bottom"><span class="price">${Number(item.price||0).toLocaleString('ru-RU')} ₽</span><button class="buy-button" type="button" data-favorite-buy="${esc(item.id)}">Купить</button><button class="heart-button is-favorite" type="button" data-favorite-remove="${esc(item.id)}" aria-label="Убрать из избранного">♥</button></div></div></article>`;
    }).join('')}</div>`;
    host.querySelectorAll('[data-favorite-remove]').forEach(button=>button.addEventListener('click',async()=>{
      const id=button.dataset.favoriteRemove;button.disabled=true;
      try{
        if(SB){await SB.toggleFavoriteListing(id);remoteFavoriteIds.delete(String(id))}
        else{const set=favorites();set.delete(String(id));setFavs(set)}
        notify('Товар убран из избранного');render();await showFavorites();
      }catch(error){notify(SB?SB.ruError(error):'Не удалось удалить товар');button.disabled=false}
    }));
    host.querySelectorAll('[data-favorite-buy]').forEach(button=>button.addEventListener('click',()=>{
      const item=items.find(row=>String(row.id)===String(button.dataset.favoriteBuy));
      if(!item)return;
      const product={id:item.id,title:item.title,desc:item.description||'Цифровой товар',price:Number(item.price)||0,category:item.category||'other',symbol:'✦',label:'KLB',seller:item.seller||'',image:item.image_url||''};
      if(SB){closeModal();checkoutDialog(product)}else{notify('Покупка доступна после подключения Supabase')}
    }));
  }catch(error){const host=$('#favoritesContent');if(host){host.className='form-error';host.textContent=SB?SB.ruError(error):'Не удалось загрузить избранное.'}}
}
function marketplaceStatus(status){return status==='paid'?'Ожидает выполнения продавцом':status==='seller_completed'?'Продавец подтвердил выполнение':status==='completed'?'Сделка завершена':status==='disputed'?'Открыт спор':status==='refunded'?'Средства возвращены':status}
function marketplaceItemName(category){return ({games:'игрового товара',keys:'ключа или кода',subscriptions:'подписки',accounts:'аккаунта',services:'услуги',other:'товара или услуги'})[category]||'товара или услуги'}
async function openChats(preferredChatId=null){if(!current){authDialog('login');notify('Войди в аккаунт, чтобы открыть чаты');return}if(!SB){modal('Чаты','<div class="empty-modal">Чаты доступны после подключения Supabase.</div>');return}modal('Чаты и сделки','<div id="chatListContent" class="empty-modal">Загружаем чаты…</div>');try{await refreshWallet();const chats=await SB.myChats();if(preferredChatId&&chats.some(c=>c.id===preferredChatId)){await openChat(preferredChatId,chats);return}const host=$('#chatListContent');if(!chats.length){host.className='empty-modal';host.textContent='Пока нет сделок. После оплаты заказа здесь появится чат с продавцом.';return}host.className='deal-list funpay-chat-list';host.innerHTML=chats.map(c=>{const o=c.order||{},last=c.latestMessage;return `<button class="chat-list-item funpay-chat-preview" data-open-chat="${esc(c.id)}"><span class="chat-list-main"><b>${esc(o.listing_title||'Заказ')}</b><small>${esc(c.otherUsername)} · ${esc(marketplaceStatus(o.status||''))}</small><small class="chat-last-message">${last?esc(last.body):'Чат создан после оплаты'}</small></span><span class="chat-list-price">${Number(o.gross_amount||0).toLocaleString('ru-RU')} ₽</span></button>`}).join('');host.querySelectorAll('[data-open-chat]').forEach(b=>b.onclick=()=>openChat(b.dataset.openChat,chats))}catch(e){const host=$('#chatListContent');if(host){host.className='form-error';host.textContent=SB.ruError(e)}}}
async function refreshChatLive(chatId,knownStatus){try{if(!$('#chatMessages'))return;const chats=await SB.myChats();const chat=chats.find(c=>c.id===chatId);if(!chat)return;const nextStatus=chat.order?.status||'';if(nextStatus!==knownStatus){const draft=$('#chatSendForm')?.elements.body.value||'';if(current.id===chat.seller_id&&nextStatus==='completed'){await refreshWallet();notify('Покупатель подтвердил получение. Средства зачислены на твой баланс.')}await openChat(chatId,chats);if($('#chatSendForm'))$('#chatSendForm').elements.body.value=draft;return}const messages=await SB.chatMessages(chatId);const box=$('#chatMessages');if(!box)return;const atBottom=box.scrollHeight-box.scrollTop-box.clientHeight<90;box.innerHTML=messages.length?messages.map(m=>`<div class="chat-message ${m.sender_id===current.id?'chat-message-own':''}"><div>${esc(m.body)}</div><small>${new Date(m.created_at).toLocaleString('ru-RU')}</small></div>`).join(''):'<div class="empty-modal">Начните общение по заказу.</div>';if(atBottom)box.scrollTop=box.scrollHeight}catch(e){console.warn('Chat refresh:',e)}}
async function openChat(chatId,cachedChats=null){try{
const chats=cachedChats||await SB.myChats();const chat=chats.find(c=>c.id===chatId);if(!chat){notify('Чат не найден или у тебя нет доступа');return}const order=chat.order||{},messages=await SB.chatMessages(chatId),status=order.status||'',seller=current.id===chat.seller_id,buyer=current.id===chat.buyer_id,otherId=chat.otherUserId|| (seller?chat.buyer_id:chat.seller_id);let action='';
if(seller&&status==='paid')action='<button class="primary-action" id="sellerCompleteOrder">Подтвердить выполнение заказа</button><p class="modal-lead">После твоего подтверждения покупатель проверит получение '+esc(marketplaceItemName(order.listing_category))+' . Деньги поступят тебе только после его подтверждения.</p>';
else if(buyer&&status==='seller_completed')action='<button class="primary-action" id="buyerConfirmOrder">Подтверждаю получение '+esc(marketplaceItemName(order.listing_category))+'</button><p class="modal-lead">Подтверждай только после фактического получения. После этого продавцу будет начислена оплата за вычетом комиссии 5%.</p>';
else if(status==='completed')action='<p class="chat-complete-note">✓ Сделка завершена. Продавцу начислено '+Number(order.seller_net||0).toLocaleString('ru-RU')+' ₽ после комиссии 5%.</p>';
else if(buyer&&status==='paid')action='<p class="modal-lead">Оплата получена площадкой и удерживается до подтверждения выполнения продавцом.</p>';
else if(seller&&status==='seller_completed')action='<p class="modal-lead">Ожидаем подтверждения получения от покупателя. Оплата пока удерживается.</p>';
else if(status==='refunded')action='<p class="chat-complete-note">Средства возвращены покупателю по решению администрации.</p>';
if(chat.dispute?.status==='open')action+='<p class="chat-dispute-note">⚑ Спор открыт. Ожидайте решения администрации.</p>';
else if(chat.dispute?.status==='approved')action+='<p class="chat-dispute-note">Спор удовлетворён администрацией. Средства возвращены покупателю.</p>';
else if(chat.dispute?.status==='rejected')action+='<p class="chat-dispute-note">Администрация не выявила нарушений. Возврата средств нет.</p>';
if(buyer&&status==='completed'&&!chat.review)action+='<button class="secondary-action" id="chatLeaveReview">★ Оставить отзыв</button>';
else if(buyer&&chat.review)action+='<p class="modal-lead">✓ Отзыв отправлен: '+Number(chat.review.rating)+'/5</p>';
if(buyer&&['paid','seller_completed','completed'].includes(status)&&!chat.dispute)action+='<button class="secondary-action" id="chatOpenDispute">⚑ Оспорить товар / услугу</button>';
modal('Чат по заказу',`<div class="funpay-chat-shell"><div class="funpay-chat-head"><div><span class="overline">KLB STORE · ЗАКАЗ</span><h3>${esc(order.listing_title||'Заказ')}</h3><small>${esc(chat.otherUsername)} · ${esc(marketplaceStatus(status))}</small></div><div class="funpay-chat-price">${Number(order.gross_amount||0).toLocaleString('ru-RU')} ₽</div></div><div class="chat-participant-actions"><button type="button" class="secondary-action" id="chatViewProfile">Профиль ${seller?'покупателя':'продавца'} · ${esc(chat.otherUsername)}</button><button type="button" class="text-btn" id="chatReportUser">Пожаловаться</button></div><div class="chat-order-summary"><b>${esc(order.listing_title||'Заказ')}</b><span>${esc(marketplaceStatus(status))}</span><small>Сумма заказа: ${Number(order.gross_amount||0).toLocaleString('ru-RU')} ₽ · Количество: ${Number(order.quantity||1)}</small>${seller?`<small>Твоё начисление после подтверждения: ${Number(order.seller_net||0).toLocaleString('ru-RU')} ₽ (комиссия 5%: ${Number(order.commission_amount||0).toLocaleString('ru-RU')} ₽)</small>`:''}</div>${action}<div class="chat-toolbar"><span>Переписка по заказу</span><button type="button" class="text-btn" id="refreshChat">Обновить</button></div><div class="chat-messages" id="chatMessages">${messages.length?messages.map(m=>`<div class="chat-message ${m.sender_id===current.id?'chat-message-own':''}"><div>${esc(m.body)}</div><small>${new Date(m.created_at).toLocaleString('ru-RU')}</small></div>`).join(''):'<div class="empty-modal">Начните общение по заказу.</div>'}</div><form id="chatSendForm" class="chat-send-form"><textarea name="body" rows="2" maxlength="4000" required placeholder="Напиши сообщение по заказу…"></textarea><button class="primary-action" type="submit">Отправить</button></form><button type="button" class="link-action" id="backToChats">← Все чаты</button></div>`);document.querySelector('#appModal .app-modal')?.classList.add('funpay-chat-modal');
const messageBox=$('#chatMessages');if(messageBox)messageBox.scrollTop=messageBox.scrollHeight;
$('#chatViewProfile').onclick=()=>showPublicProfile(otherId,chatId);
$('#chatReportUser').onclick=()=>openAccountReport(otherId,chat.otherUsername,chatId);
$('#refreshChat').onclick=()=>openChat(chatId);$('#backToChats').onclick=()=>openChats();
$('#chatSendForm').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,field=form.elements.body,button=form.querySelector('button'),body=field.value.trim();if(!body)return;button.disabled=true;try{await SB.sendChatMessage(chatId,body);await openChat(chatId)}catch(err){notify(SB.ruError(err));button.disabled=false}};
if($('#sellerCompleteOrder'))$('#sellerCompleteOrder').onclick=async()=>{const button=$('#sellerCompleteOrder');button.disabled=true;try{await SB.sellerCompleteOrder(order.id);notify('Выполнение отмечено. Ожидаем подтверждения покупателя.');await openChat(chatId)}catch(e){notify(SB.ruError(e));button.disabled=false}};
if($('#buyerConfirmOrder'))$('#buyerConfirmOrder').onclick=async()=>{if(!confirm('Подтверждаешь, что получил товар или услугу? После этого деньги будут перечислены продавцу, отменить подтверждение нельзя.'))return;const button=$('#buyerConfirmOrder');button.disabled=true;try{const result=await SB.confirmOrderReceived(order.id);await refreshWallet();notify(`Сделка завершена. Продавцу начислено ${Number(result.seller_net||0).toLocaleString('ru-RU')} ₽.`);await openChat(chatId)}catch(e){notify(SB.ruError(e));button.disabled=false}};
if($('#chatLeaveReview'))$('#chatLeaveReview').onclick=()=>openReviewDialog(order.id,chatId);
if($('#chatOpenDispute'))$('#chatOpenDispute').onclick=()=>openDisputeDialog(order.id,chatId);
chatRefreshTimer=setInterval(()=>refreshChatLive(chatId,status),10000);
}catch(e){notify(SB.ruError(e))}}
function sellerApply(){if(!current){authDialog('login');notify('Войди в аккаунт, чтобы подать заявку');return}if(SB&&!sellerApply.ok){SB.myApplication().then(a=>{if(a&&a.status==='approved'){notify('Ты уже одобрен как продавец');return}if(a&&a.status==='pending'){notify('Твоя заявка уже отправлена');return}sellerApply.ok=true;sellerApply();sellerApply.ok=false}).catch(e=>notify(SB.ruError(e)));return}const existing=read(SELLERS,[]).find(s=>s.userId===current.id&&['Новая','На рассмотрении','Одобрена'].includes(s.status));if(existing){notify(existing.status==='Одобрена'?'Ты уже одобрен как продавец': 'Твоя заявка уже отправлена');return}modal('Заявка продавца',`<p class="modal-lead">Расскажи о себе. Заявка появится в админ-панели и будет рассмотрена администрацией.</p><form id="sellerForm" class="modal-form"><label>Твой никнейм на KLB STORE<input name="nickname" value="${esc(current.username)}" required maxlength="32"></label><label>Описание<textarea name="description" required minlength="20" maxlength="700" rows="4" placeholder="Расскажи о себе и опыте"></textarea></label><label>Чем будешь полезен пользователям?<textarea name="benefit" required minlength="20" maxlength="700" rows="3" placeholder="Какие товары или услуги планируешь предлагать"></textarea></label><label>Возраст<input name="age" type="number" min="18" max="120" required></label><label>Telegram username<input name="telegram" required placeholder="@username" pattern="@?[A-Za-z0-9_]{5,32}"></label><p class="form-error" id="sellerError"></p><button class="primary-action" type="submit">Отправить заявку</button></form>`);$('#sellerForm').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.target),age=Number(f.get('age'));if(age<18||age>120){$('#sellerError').textContent='Возраст должен быть от 18 до 120 лет.';return}if(SB){sbSubmitSeller({nickname:f.get('nickname').trim(),description:f.get('description').trim(),benefit:f.get('benefit').trim(),age,telegram:f.get('telegram').trim().replace(/^@/,'@')});return}const list=read(SELLERS,[]);list.push({id:'S'+Date.now(),userId:current.id,name:f.get('nickname').trim(),username:current.username,description:f.get('description').trim(),benefit:f.get('benefit').trim(),age,telegram:f.get('telegram').trim().replace(/^@/,'@'),date:new Date().toLocaleString('ru-RU'),status:'Новая'});write(SELLERS,list);const ix=users.findIndex(u=>u.id===current.id);if(ix>=0){users[ix].sellerStatus='На рассмотрении';write(STORE,users)}closeModal();notify('Заявка отправлена! Администратор рассмотрит её.')});}
async function sbSubmitSeller(v){const btn=document.querySelector('#sellerForm button[type=submit]');btn.disabled=true;try{await SB.applyForSeller(v);closeModal();notify('Заявка отправлена! Администратор рассмотрит её.')}catch(e){$('#sellerError').textContent=SB.ruError(e);btn.disabled=false}}
function ensureLogin(action){if(current){action();return}authDialog('login')}
async function checkoutDialog(product){
  await refreshWallet();
  const subtotal=Number(product.price)||0;
  let activePromo=null,discount=0;
  try{activePromo=await SB.myActiveMarketplacePromo()}catch(err){console.warn('KLB promo lookup failed:',err)}
  if(activePromo){
    const value=Number(activePromo.discount_value)||0;
    if(activePromo.discount_type==='percent') discount=Math.round((subtotal*value/100+Number.EPSILON)*100)/100;
    else discount=Math.min(value,Math.max(0,subtotal-0.01));
    discount=Math.min(discount,Math.max(0,subtotal-0.01));
  }
  const payable=Math.max(0.01,Math.round((subtotal-discount+Number.EPSILON)*100)/100);
  const promoMarkup=activePromo?`<div class="checkout-promo-applied"><b>Промокод ${esc(activePromo.code)} применён</b><span>Скидка −${discount.toLocaleString('ru-RU')} ₽</span></div>`:'<p class="modal-lead">Есть промокод? Активируй его в своём профиле перед покупкой.</p>';
  modal('Оплата заказа',`<div class="chat-order-summary"><b>${esc(product.title)}</b><span>Продавец: ${esc(product.seller||'KLB STORE')}</span>${discount?`<small>Стоимость без скидки: ${subtotal.toLocaleString('ru-RU')} ₽</small>`:''}<small>К оплате: ${payable.toLocaleString('ru-RU')} ₽</small></div>${promoMarkup}<p class="modal-lead">Сумма спишется с доступного баланса и будет удерживаться площадкой. Продавец получит оплату после выполнения заказа и твоего подтверждения. Комиссия сервиса 5% удерживается из суммы продавца, а не добавляется к твоей оплате.</p><p>Доступно на балансе: <b>${walletBal.toLocaleString('ru-RU')} ₽</b></p><p class="form-error" id="checkoutError"></p><button class="primary-action" id="confirmCheckout" ${walletBal<payable?'disabled':''}>Оплатить ${payable.toLocaleString('ru-RU')} ₽</button>${walletBal<payable?'<p class="modal-lead">Недостаточно средств. Пополни баланс в кошельке.</p><button class="secondary-action" id="checkoutTopUp">Пополнить баланс</button>':''}`);
  $('#confirmCheckout').onclick=async()=>{const btn=$('#confirmCheckout');btn.disabled=true;try{const result=await SB.createMarketplaceOrder(product.id,1,subtotal);await refreshWallet();const paid=Number(result.gross_amount??payable);notify(`Оплата ${paid.toLocaleString('ru-RU')} ₽ прошла. Чат с продавцом создан.`);await openChats(result.chat_id)}catch(e){$('#checkoutError').textContent=SB.ruError(e);btn.disabled=false}};
  if($('#checkoutTopUp'))$('#checkoutTopUp').onclick=()=>depositDialog();
}

const demoProducts=[];
if(!localStorage.getItem('klb_products_cleared_v1')){write(LISTINGS,[]);localStorage.setItem('klb_products_cleared_v1','1')}
let saved=read(LISTINGS,null),products=SB?[]:saved?saved.filter(p=>p.status==='Активно').map(p=>({id:p.id,title:p.title,desc:p.description||'Цифровой товар',price:Number(p.price)||0,category:p.category||'other',catalog_category:p.catalog_category||'other',catalog_subcategory:p.catalog_subcategory||'other',symbol:'✦',label:'KLB',seller:p.seller,image:p.image,seller_rating:Number(p.seller_rating||0),seller_review_count:Number(p.seller_review_count||0),promotion_rank:Number(p.promotion_rank||0),is_store:p.is_store||false})):demoProducts;
const grid=$('#productGrid'),search=$('#searchInput'),sort=$('#sortSelect'),empty=$('#emptyState'),favCount=$('#favoriteCount');
function favorites(){if(SB)return new Set(remoteFavoriteIds);const f=read(FAV,{});return new Set(f[current?.id||'guest']||[])}function setFavs(s){if(SB){remoteFavoriteIds=new Set(s);return}const f=read(FAV,{});f[current?.id||'guest']=[...s];write(FAV,f)}
function setCatalogContext(){
  const context=$('#categoryContext'),title=$('#catalogTitle'),overline=$('#catalogOverline'),heroTitle=$('#categoryHeroTitle'),heroDescription=$('#categoryHeroDescription'),heroMark=$('#categoryHeroMark'),tabs=$('#subcategoryTabs');
  if(!activeRootCategory){context.hidden=true;title.textContent='Товары';overline.textContent='ВИТРИНА KLB';return}
  const cat=categoryForSlug(activeRootCategory);context.hidden=false;heroTitle.textContent=cat.name;heroDescription.textContent=cat.description;heroMark.textContent=cat.mark;title.textContent=activeSubcategory==='all'?cat.name:catalogSubcategoryName(cat.slug,activeSubcategory);overline.textContent='КАТЕГОРИЯ KLB';
  tabs.innerHTML=`<button type="button" class="subcategory-tab ${activeSubcategory==='all'?'active':''}" data-subcategory="all">Все товары</button>${cat.subs.map(([slug,label])=>`<button type="button" class="subcategory-tab ${activeSubcategory===slug?'active':''}" data-subcategory="${slug}">${esc(label)}</button>`).join('')}`;
}
function sortCatalog(list){
  const mode=sort.value;
  if(mode==='low')return list.sort((a,b)=>Number(a.price||0)-Number(b.price||0)||organicListingCompare(a,b));
  if(mode==='high')return list.sort((a,b)=>Number(b.price||0)-Number(a.price||0)||organicListingCompare(a,b));
  if(mode==='rating')return list.sort(organicListingCompare);
  if(activeRootCategory)return arrangeCategoryListings(list);
  const store=list.filter(p=>p.is_store||p.seller==='KLB STORE');
  const sellers=list.filter(p=>!(p.is_store||p.seller==='KLB STORE')).sort(organicListingCompare);
  return [...store.sort((a,b)=>String(b.created_at||'').localeCompare(String(a.created_at||''))),...sellers];
}
function render(){
  const f=favorites();
  let list=products.filter(p=>(!activeRootCategory||String(p.catalog_category||'other')===activeRootCategory)&&(activeSubcategory==='all'||String(p.catalog_subcategory||'other')===activeSubcategory)&&(`${p.title} ${p.desc} ${p.seller||''}`.toLowerCase().includes(search.value.toLowerCase())));
  list=sortCatalog(list);
  grid.innerHTML=list.map(p=>{
    const rating=Number(p.seller_rating||0),reviews=Number(p.seller_review_count||0),promoted=Number(p.promotion_rank)>0;
    const badge=promoted?'<span class="product-promotion-badge">ТОП КАТЕГОРИИ</span>':(p.is_store||p.seller==='KLB STORE'?'<span class="product-store-badge">KLB STORE</span>':'<span class="product-label">KLB</span>');
    return `<article class="product-card"><div class="product-image">${badge}${p.image?`<img src="${esc(p.image)}" alt="${esc(p.title)}" loading="lazy" style="width:100%;height:100%;object-fit:cover;border-radius:12px">`:`<span class="placeholder-symbol">${esc(p.symbol||'✦')}</span>`}</div><div class="product-info"><div class="product-card-category">${esc(categoryForSlug(p.catalog_category).name)} · ${esc(catalogSubcategoryName(p.catalog_category,p.catalog_subcategory))}</div><h3>${esc(p.title)}</h3><p>${esc(p.desc||p.description||'Цифровой товар')}</p>${p.seller?`<small class="product-seller">${p.seller==='KLB STORE'?'Магазин KLB STORE':`Продавец: ${esc(p.seller)}`}</small>`:''}<div class="product-rating-line">${reviews?`<span>★ ${rating.toFixed(2)}</span><small>${reviews} отзывов продавца</small>`:'<small>Пока без отзывов</small>'}</div><div class="product-bottom"><span class="price">${Number(p.price||0).toLocaleString('ru-RU')} ₽</span><button class="buy-button" data-product="${esc(p.id)}">Купить</button><button class="heart-button ${f.has(String(p.id))?'is-favorite':''}" data-fav="${esc(p.id)}" aria-label="В избранное">${f.has(String(p.id))?'♥':'♡'}</button></div></div></article>`;
  }).join('');
  empty.hidden=list.length>0;empty.textContent=activeRootCategory?'В этой подкатегории пока нет одобренных объявлений.':'Пока нет одобренных объявлений. Загляни позже.';favCount.textContent=f.size;
  const count=$('#catalogResultCount');if(count)count.textContent=`Найдено товаров: ${list.length}`;
}
document.querySelectorAll('[data-root-category]').forEach(btn=>btn.addEventListener('click',()=>{
  activeRootCategory=btn.dataset.rootCategory==='all'?null:btn.dataset.rootCategory;activeSubcategory='all';
  document.querySelectorAll('[data-root-category]').forEach(b=>b.classList.toggle('active',b===btn));
  setCatalogContext();render();
  document.getElementById('catalog').scrollIntoView({behavior:'smooth',block:'start'});
}));
$('#categoryBack').onclick=()=>{activeRootCategory=null;activeSubcategory='all';document.querySelectorAll('[data-root-category]').forEach(b=>b.classList.toggle('active',b.dataset.rootCategory==='all'));setCatalogContext();render();document.getElementById('categories').scrollIntoView({behavior:'smooth',block:'start'})};
$('#subcategoryTabs').addEventListener('click',e=>{const btn=e.target.closest('[data-subcategory]');if(!btn)return;activeSubcategory=btn.dataset.subcategory;setCatalogContext();render()});
search.addEventListener('input',render);sort.addEventListener('change',render);
grid.addEventListener('click', async e => {
  const fav=e.target.closest('[data-fav]');
  if(fav){if(!current){authDialog('signup');notify('Создай аккаунт или войди, чтобы добавлять товары в избранное.');return;}const id=String(fav.dataset.fav),set=favorites();fav.disabled=true;try{if(SB){const added=await SB.toggleFavoriteListing(id);added?set.add(id):set.delete(id)}else{set.has(id)?set.delete(id):set.add(id);setFavs(set)}if(SB)remoteFavoriteIds=new Set(set);render()}catch(error){notify(SB?SB.ruError(error):'Не удалось изменить избранное');fav.disabled=false}return;}
  const buy=e.target.closest('[data-product]');if(!buy)return;const product=products.find(p=>String(p.id)===buy.dataset.product);if(!product)return;
  if(SB){if(!current){authDialog('login');notify('Войди в аккаунт, чтобы купить товар');return;}checkoutDialog(product);return;}
  ensureLogin(()=>{const orders=read(ORDERS,[]);orders.push({id:'KL-'+Date.now().toString().slice(-6),buyer:current.username,buyerId:current.id,product:product.title,productId:product.id,seller:product.seller||'KLB STORE',price:product.price,status:'Новый',created:new Date().toLocaleString('ru-RU')});write(ORDERS,orders);modal('Демо-заказ создан',`<div class="order-success"><span>✓</span><h3>Заказ сохранён в демо-режиме</h3><p>${esc(product.title)}</p><b>${Number(product.price).toLocaleString('ru-RU')} ₽</b><p class="modal-lead">Для реальной оплаты, чатов и удержания средств подключи Supabase и выполни миграцию маркетплейса.</p></div>`)});
});
$('#favoritesBtn').onclick=()=>{if(!current){authDialog('signup');return}showFavorites()};$('#loginBtn').onclick=()=>current?profileMenu():authDialog('login');if($('#chatsBtn'))$('#chatsBtn').onclick=()=>openChats();$('#sellerBtn').onclick=sellerApply;refreshHeader();setCatalogContext();render();
async function loadCatalog(){try{if(!SB)return;products=(await SB.catalog()).map(p=>({id:p.id,seller_id:p.seller_id,title:p.title,description:p.description,desc:p.description||'Цифровой товар',price:Number(p.price)||0,category:p.category||'other',catalog_category:p.catalog_category||'other',catalog_subcategory:p.catalog_subcategory||'other',stock:Number(p.stock||0),created_at:p.created_at,image:p.image_url||'',symbol:'✦',label:'KLB',seller:p.seller||'',is_store:p.seller_role==='admin',seller_rating:Number(p.seller_rating||0),seller_review_count:Number(p.seller_review_count||0),promotion_rank:Number(p.promotion_rank||0),promoted_at:p.promoted_at||null}));render()}catch(e){console.error(e);notify(SB.ruError(e)||'Не удалось загрузить каталог')}}
const telegramCallbackParams=new URLSearchParams(location.search);
if(telegramCallbackParams.has('code')||telegramCallbackParams.has('error')){
  handleTelegramOidcCallback().catch(error=>{
    console.error('KLB Telegram OIDC callback:',error);
    const message=SB?.ruError?SB.ruError(error):String(error.message||error);
    refreshProfile().then(refreshHeader);
    modal('Не удалось войти через Telegram',`<p class="form-error">${esc(message)}</p><p class="modal-lead">Telegram вернул пользователя на сайт, но KLB STORE не завершил вход. Скопируй текст ошибки для диагностики.</p><button class="primary-action" id="telegramOidcRetry">Повторить вход</button><button class="secondary-action" id="telegramOidcClose">Закрыть</button>`);
    $('#telegramOidcRetry').onclick=()=>{closeModal();authDialog('login')};
    $('#telegramOidcClose').onclick=closeModal;
  });
}else if(window.Telegram?.WebApp?.initData){
  handleTelegramMiniAppStartup().catch(async error=>{
    console.error('KLB Telegram Mini App auth:',error);
    try{await refreshProfile();await loadCatalog();}catch{}
    modal('Не удалось войти через Telegram',`<p class="form-error">${esc(SB?.ruError?SB.ruError(error):String(error.message||error))}</p><p class="modal-lead">Проверь публикацию функции telegram-auth и секрет TELEGRAM_BOT_TOKEN в Supabase.</p><button class="primary-action" id="telegramMiniAppRetry">Повторить вход</button>`);
    $('#telegramMiniAppRetry').onclick=()=>handleTelegramMiniAppStartup(true).catch(e=>notify(SB?.ruError?SB.ruError(e):String(e.message||e)));
  });
}else if(SB)refreshProfile().then(()=>{refreshHeader();return loadCatalog()}).then(()=>{if(sessionStorage.getItem(PENDING_CHAT))openPendingChatIfReady()});
})();
