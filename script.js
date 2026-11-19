const products = [
 {title:"Цифровой игровой товар",desc:"Моментальная или ручная выдача продавцом",price:590,category:"games",symbol:"✦",label:"ПОПУЛЯРНО"},
 {title:"Ключ активации",desc:"Код для активации цифрового продукта",price:1290,category:"keys",symbol:"⌘",label:"КЛЮЧ"},
 {title:"Премиум подписка",desc:"Подписка на цифровой сервис",price:990,category:"subscriptions",symbol:"◉",label:"ПОДПИСКА"},
 {title:"Игровой аккаунт",desc:"Подробности и характеристики в описании",price:2490,category:"accounts",symbol:"◎",label:"АККАУНТ"},
 {title:"Цифровой набор",desc:"Комплект цифровых предметов",price:790,category:"games",symbol:"✧",label:"НАБОР"},
 {title:"Подарочный код",desc:"Электронный код с инструкцией",price:1490,category:"keys",symbol:"▣",label:"КОД"},
 {title:"Доступ к сервису",desc:"Цифровой доступ с условиями продавца",price:450,category:"subscriptions",symbol:"∞",label:"ДОСТУП"},
 {title:"Другой цифровой товар",desc:"Уточняйте состав товара перед покупкой",price:350,category:"other",symbol:"＋",label:"НОВИНКА"}
];
let activeCategory="all";
const grid=document.getElementById("productGrid"), search=document.getElementById("searchInput"), sort=document.getElementById("sortSelect"), empty=document.getElementById("emptyState");
function render(){
 let list=products.filter(p=>(activeCategory==="all"||p.category===activeCategory)&&(`${p.title} ${p.desc}`.toLowerCase().includes(search.value.toLowerCase())));
 if(sort.value==="low")list.sort((a,b)=>a.price-b.price); if(sort.value==="high")list.sort((a,b)=>b.price-a.price);
 grid.innerHTML=list.map(p=>`<article class="product-card"><div class="product-image"><span class="product-label">${p.label}</span><span class="placeholder-symbol">${p.symbol}</span></div><div class="product-info"><h3>${p.title}</h3><p>${p.desc}</p><div class="product-bottom"><span class="price">${p.price.toLocaleString("ru-RU")} ₽</span><button class="buy-button" data-buy="${p.title}">Подробнее</button></div></div></article>`).join("");
 empty.hidden=list.length>0;
}
document.querySelectorAll(".category").forEach(btn=>btn.addEventListener("click",()=>{document.querySelectorAll(".category").forEach(b=>b.classList.remove("active"));btn.classList.add("active");activeCategory=btn.dataset.category;render()}));
search.addEventListener("input",render);sort.addEventListener("change",render);
const toast=document.getElementById("toast");let toastTimer;
function showToast(msg){toast.textContent=msg;toast.classList.add("show");clearTimeout(toastTimer);toastTimer=setTimeout(()=>toast.classList.remove("show"),2600)}
grid.addEventListener("click",e=>{const b=e.target.closest("[data-buy]");if(b)showToast("Демо-каталог: карточка товара будет подключена на следующем этапе")});
document.getElementById("loginBtn").addEventListener("click",()=>showToast("Авторизация появится на этапе подключения базы данных"));
document.getElementById("sellerBtn").addEventListener("click",()=>showToast("Доступ продавца выдаёт администрация KLB STORE"));
render();
