const main = document.querySelector('#main'), tabs = document.querySelector('#tabs'), notice = document.querySelector('#notice'), account = document.querySelector('#account');
let token = '', me = null, tab = '', busy = false, config = null, products = [], orders = [], timer = null, transport = { enabled:false, jobs:[] }, management=[];
let productShopId = null;
const productsPath = () => me.role === 'admin' ? `/admin/shops/${productShopId}/products` : '/merchant/products';
const imagesPath = () => me.role === 'admin' ? `/admin/shops/${productShopId}/images` : '/merchant/images';
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = v => Number(v || 0).toLocaleString('ru-RU') + ' сум';
const statusNames = { pending_shop: 'Новый заказ', confirmed: 'Подтверждён магазином', ready: 'Готов к выдаче', assigned: 'Курьер назначен', accepted: 'Курьер принял', picked_up: 'Товар у курьера', completed: 'Доставлен', cancelled: 'Отменён', rejected: 'Магазин отказал' };
const financeNames = { merchant_cash_received:'Магазины получили наличные',courier_cash_advanced:'Курьеры оплатили товары',courier_cash_received:'Курьеры получили от клиентов',goods_reimbursement:'Возмещение стоимости товаров',delivery_cash_earned:'Оплата доставки до комиссии TaxiMaster', driver_cash_receivable: 'Наличные у курьеров', courier_payable: 'К выплате курьерам', merchant_payable: 'К выплате магазинам', service_revenue: 'Комиссия службы' };
const field = (name, title, value = '', type = 'text', extra = '') => `<label>${esc(title)}<input name="${esc(name)}" type="${type}" value="${esc(value)}" ${extra} required></label>`;
const check = (name, label, value) => `<label class="check"><input name="${name}" type="checkbox" ${value ? 'checked' : ''}>${label}</label>`;
const options = (list, value) => list.map(x => `<option value="${x.id}" ${x.id === value ? 'selected' : ''}>${esc(x.name)}</option>`).join('');
const choose = (name, title, list, value) => `<label>${title}<select name="${name}" required><option value="">Выбрать</option>${options(list, value)}</select></label>`;
const empty = title => `<p class="empty">${title}</p>`;
async function request(path, { method = 'GET', body, key, raw = false } = {}) {
  const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 20000);
  try {
  const response = await fetch('/api/delivery' + path, { signal:controller.signal, method, headers: { ...(token ? { Authorization: 'Bearer ' + token } : {}), ...(body !== undefined && !raw ? { 'Content-Type': 'application/json' } : {}), ...(key ? { 'Idempotency-Key': key } : {}) }, body: body === undefined ? undefined : raw ? body : JSON.stringify(body) });
  let value; try { value = await response.json(); } catch { throw new Error('Сервер вернул непонятный ответ'); }
  if (!response.ok || !value.ok) {
    if (response.status === 401 && token) { logoutLocal(); throw new Error('Сессия истекла. Войдите снова.'); }
    throw new Error(value.error?.message || 'Не удалось выполнить запрос');
  }
  return value.data;
  } catch (e) { if (e.name === 'AbortError') throw new Error('Нет ответа сервера. Обновите данные или повторите действие.'); throw e; }
  finally { clearTimeout(timeout); }
}
async function perform(fn) {
  if (busy) return; busy = true; notice.textContent = '';
  document.querySelectorAll('button').forEach(b => { b.disabled = true; });
  try { await fn(); } catch (e) { notice.textContent = e.message || 'Нет связи с сервером'; }
  finally { busy = false; document.querySelectorAll('button').forEach(b => { b.disabled = false; }); }
}
function commandKey(order, action) {
  const name = `delivery-command:${order.id}:${order.version}:${action}`;
  let value = sessionStorage.getItem(name);
  if (!value) { value = Array.from(crypto.getRandomValues(new Uint8Array(20)), n => n.toString(16).padStart(2, '0')).join(''); sessionStorage.setItem(name, value); }
  return value;
}
function logoutLocal() { token = ''; me = null; clearInterval(timer); timer = null; tabs.innerHTML = ''; account.innerHTML = ''; loginView(); }
function loginView() {
  main.innerHTML = '<h1>Кабинет партнёра</h1><p>Войдите с доступом, выданным администратором Yangi Taxi.</p><form id="login">' + field('login', 'Логин', '', 'text', 'autocomplete="username" maxlength="80"') + field('password', 'Пароль', '', 'password', 'autocomplete="current-password" maxlength="128"') + '<button>Войти</button></form>';
  document.querySelector('#login').onsubmit = event => { event.preventDefault(); const form = event.currentTarget; perform(async () => {
    const data = Object.fromEntries(new FormData(form)); const session = await request('/auth/login', { method: 'POST', body: data });
    form.reset(); token = session.token; me = await request('/me');
    account.innerHTML = `<span>${esc(me.login)}</span><button class="secondary" id="logout">Выйти</button>`;
    document.querySelector('#logout').onclick = () => perform(async () => { await request('/auth/logout', { method: 'POST' }); logoutLocal(); });
    await show(me.role === 'admin' ? 'shops' : 'products');
    timer = setInterval(() => { if (tab === 'orders' && !busy) perform(() => show('orders')); }, 30000);
  }); };
}
async function show(next) {
  if (!me) return; tab = next;
  const sections = me.role === 'admin' ? [['shops','Магазины'],['products','Товары'],['categories','Категории'],['pricing','Тариф доставки'],['orders','Заказы'],['finance','Финансы']] : [['products','Товары'],['orders','Заказы'],['finance','Финансы']];
  tabs.innerHTML = sections.map(([id, title]) => `<button data-tab="${id}" class="${id === tab ? 'selected' : ''}">${title}</button>`).join('');
  tabs.querySelectorAll('button').forEach(button => { button.onclick = () => perform(() => show(button.dataset.tab)); });
  if (me.role === 'admin') config = await request('/admin/config');
  if (tab === 'shops') shopsView();
  else if (tab === 'categories') categoriesView();
  else if (tab === 'pricing') await pricingView();
  else if (tab === 'products') {
    if (me.role === 'admin') {
      if (!config.shops.length) { main.innerHTML=empty('Сначала добавьте магазин.'); return; }
      if (!config.shops.some(s=>s.id===productShopId)) productShopId=config.shops[0].id;
    }
    products = await request(productsPath()); productsView();
    if (me.role === 'admin') {
      const label=document.createElement('label'); label.textContent='Магазин';
      const select=document.createElement('select'); select.innerHTML=options(config.shops,productShopId);
      select.onchange=()=>{
        if(busy){select.value=String(productShopId);return;}
        perform(async()=>{
          const previous=productShopId;
          try{productShopId=Number(select.value);await show('products');}
          catch(e){productShopId=previous;select.value=String(previous);throw e;}
        });
      };
      label.append(select);main.querySelector('h1').after(label);
    }
  }
  else if (tab === 'orders') { orders = await request(me.role === 'admin' ? '/admin/orders' : '/merchant/orders'); if (me.role === 'admin') { transport = await request('/admin/transport'); management=await request('/admin/management'); } ordersView(); }
  else if (tab === 'finance') financeView(await request(me.role === 'admin' ? '/admin/finance' : '/merchant/finance'));
}
function shopsView() {
  main.innerHTML = '<h1>Магазины</h1><button id="new-shop">Добавить магазин</button><div style="height:16px"></div>' + config.shops.map(s => `<article class="card"><div class="row"><b>${esc(s.name)}</b><span class="badge">${s.active ? 'Работает' : 'Отключён'}</span></div><p>${esc(s.address)}</p><div class="muted">Комиссия партнёра (история): ${s.commission_bps / 100}%</div><div class="actions"><button data-shop="${s.id}" class="secondary">Изменить</button></div></article>`).join('');
  document.querySelector('#new-shop').onclick = () => shopForm();
  main.querySelectorAll('[data-shop]').forEach(b => { b.onclick = () => shopForm(config.shops.find(s => s.id === Number(b.dataset.shop))); });
}
function shopForm(shop) {
  if (!config.categories.length) { notice.textContent = 'Сначала добавьте категорию магазина.'; return; }
  const s = shop || {};
  main.innerHTML = `<h1>${shop ? 'Изменить магазин' : 'Новый магазин'}</h1><form id="shop-form">${field('name','Название',s.name)}${field('address','Адрес',s.address)}${field('lat','Широта',s.lat,'number','step="any" min="-90" max="90"')}${field('lon','Долгота',s.lon,'number','step="any" min="-180" max="180"')}${choose('category_id','Категория',config.categories,s.category_id)}${choose('service_kind','Раздел GO',[{id:'food',name:'Еда'},{id:'market',name:'Маркет'}],s.service_kind)}${field('commission','Историческая комиссия партнёра, % (не комиссия TaxiMaster)',shop ? s.commission_bps / 100 : 0,'number','readonly')}${shop ? check('active','Магазин активен',s.active) : field('login','Логин партнёра','','text','autocomplete="off" minlength="3"') + field('password','Первый пароль партнёра','','password','autocomplete="new-password" minlength="12"')}<div class="full"><button>Сохранить</button><button type="button" class="secondary" id="back">Назад</button></div></form>`;
  document.querySelector('#back').onclick = shopsView;
  document.querySelector('#shop-form').onsubmit = event => { event.preventDefault(); const form = event.currentTarget; perform(async () => {
    const input = Object.fromEntries(new FormData(form)); for (const key of ['lat','lon','category_id']) input[key] = Number(input[key]); input.commission_bps = Math.round(Number(input.commission) * 100); delete input.commission;
    if (shop) input.active = form.elements.active.checked;
    await request(shop ? '/admin/shops/' + s.id : '/admin/shops', { method: shop ? 'PUT' : 'POST', body: input }); await show('shops');
  }); };
}
function categoriesView() {
  main.innerHTML = '<h1>Категории</h1><form id="category-form">' + field('name','Название категории') + '<button>Добавить категорию</button></form>' + config.categories.map(c => `<div class="card row"><b>${esc(c.name)}</b><button class="secondary" data-category="${c.id}">${c.active ? 'Отключить' : 'Включить'}</button></div>`).join('');
  document.querySelector('#category-form').onsubmit = event => { event.preventDefault(); const name = event.currentTarget.elements.name.value; perform(async () => { await request('/admin/categories', { method:'POST', body:{ name, active:true } }); await show('categories'); }); };
  main.querySelectorAll('[data-category]').forEach(b => { b.onclick = () => perform(async () => { const c = config.categories.find(c => c.id === Number(b.dataset.category)); await request('/admin/categories/' + c.id, { method:'PUT', body:{ name:c.name, active:!c.active } }); await show('categories'); }); });
}
async function pricingView() {
  const choices=await request('/admin/pricing-options'),p=config.pricing;
  main.innerHTML='<h1>Доставка по дорожному маршруту</h1><p>Цена рассчитывается сервером TaxiMaster и фиксируется при оформлении. Стоимость километра и минимальную цену меняйте в выбранном тарифе TaxiMaster. Рисовать зоны не требуется.</p><form id="pricing-form">'+choose('tariff_id','Тариф TaxiMaster',choices.tariffs,p.tariff_id)+choose('crew_group_id','Группа экипажей',choices.groups,p.crew_group_id)+field('max_distance_m','Максимальная длина маршрута, м',p.max_distance_m??'','number','min="1" max="200000" step="1"')+check('enabled','Принимать заказы доставки',!!p.enabled)+'<button>Сохранить</button></form>';
  document.querySelector('#pricing-form').onsubmit=event=>{event.preventDefault();const form=event.currentTarget;perform(async()=>{const input=Object.fromEntries(new FormData(form));for(const k of ['tariff_id','crew_group_id','max_distance_m'])input[k]=Number(input[k]);input.enabled=form.elements.enabled.checked;input.version=p.version;await request('/admin/pricing',{method:'PUT',body:input});await show('pricing');});};
}
function productsView() {
  main.innerHTML = '<h1>Товары</h1><button id="new-product">Добавить товар</button><div style="height:16px"></div>' + (products.length ? products.map(p => `<article class="card"><div class="row"><div class="product-title">${p.image_id ? `<img class="thumb" src="/api/delivery/images/${esc(p.image_id)}" alt="">` : ''}<b>${esc(p.name)}</b></div><button class="secondary" data-product="${p.id}">Изменить</button></div><p>${money(p.price_uzs)} · Остаток: ${p.stock} · ${p.active ? 'В продаже' : 'Скрыт'}</p></article>`).join('') : empty('Добавьте первый товар и фотографию.'));
  document.querySelector('#new-product').onclick = () => productForm();
  main.querySelectorAll('[data-product]').forEach(b => { b.onclick = () => productForm(products.find(p => p.id === Number(b.dataset.product))); });
}
function productForm(product) {
  const p = product || {}; let imageId = p.image_id || null;
  main.innerHTML = `<h1>${product ? 'Изменить товар' : 'Новый товар'}</h1><form id="product-form">${field('sku','Артикул',p.sku)}${field('name','Название',p.name)}<label class="full">Описание<textarea name="description" maxlength="2000">${esc(p.description)}</textarea></label>${field('price_uzs','Цена, сум',p.price_uzs,'number','min="0" max="10000000" step="1"')}${field('stock','Доступно, шт.',p.stock,'number','min="0" max="1000000" step="1"')}<label>Фотография (PNG, JPEG, WebP; до 2 МБ)<input name="photo" type="file" accept="image/png,image/jpeg,image/webp"></label>${check('active','В продаже',product ? p.active : true)}<div class="full"><button>Сохранить</button><button id="back" class="secondary" type="button">Назад</button></div></form>`;
  catalogDetailsEditor(document.querySelector('#product-form'),p);
  recommendationsEditor(document.querySelector('#product-form'),p);
  document.querySelector('#back').onclick = () => perform(() => show('products'));
  document.querySelector('#product-form').onsubmit = event => { event.preventDefault(); const form = event.currentTarget; perform(async () => {
    const input = Object.fromEntries(new FormData(form)), file = input.photo;
    if (file?.size) { if (file.size > 2 * 1024 * 1024) throw new Error('Фото должно быть меньше 2 МБ'); imageId = (await request(imagesPath(), { method:'POST', body:file, raw:true })).id; form.elements.photo.value = ''; }
    delete input.photo; input.variants=readVariantEditor(form);input.ingredients=form.elements.ingredients.value;input.weight_g=form.elements.weight_g.value===''?null:Number(form.elements.weight_g.value);input.volume_ml=form.elements.volume_ml.value===''?null:Number(form.elements.volume_ml.value); input.recommendation_ids=JSON.parse(input.recommendation_ids); input.price_uzs = Number(input.price_uzs); input.stock = Number(input.stock); input.active = form.elements.active.checked; input.image_id = imageId; if (product) input.version = p.version;
    await request(productsPath() + (product ? '/' + p.id : ''), { method:product ? 'PUT' : 'POST', body:input }); await show('products');
  }); };
}
function catalogDetailsEditor(form,product){
 const panel=document.createElement('section');panel.className='full';
 panel.innerHTML=`<h2>Состав и варианты</h2><label>Состав<textarea name="ingredients" maxlength="2000">${esc(product.ingredients)}</textarea></label><div class="row"><label>Вес, г<input name="weight_g" type="number" min="1" max="1000000" value="${esc(product.weight_g)}"></label><label>Объём, мл<input name="volume_ml" type="number" min="1" max="1000000" value="${esc(product.volume_ml)}"></label></div><p>Для товара с вариантами общая цена «от» и остаток определяются сервером. Удалённые из продажи варианты сохраняются для истории заказов.</p><div class="tablewrap" id="variant-rows"></div><button type="button" id="new-variant">Добавить вариант</button>`;
 form.lastElementChild.before(panel);let rows=(product.variants||[]).map(v=>({...v}));
 function render(){
  panel.querySelector('#variant-rows').innerHTML=rows.map((v,i)=>`<div class="card" data-variant-row data-id="${esc(v.id||'')}"><label>Название<input data-key="name" maxlength="100" required value="${esc(v.name)}"></label><div class="row"><label>Цена, сум<input data-key="price_uzs" type="number" min="0" max="10000000" step="1" required value="${esc(v.price_uzs)}"></label><label>Остаток<input data-key="stock" type="number" min="0" max="1000000" step="1" required value="${esc(v.stock)}"></label></div><div class="row"><label>Вес, г<input data-key="weight_g" type="number" min="1" max="1000000" value="${esc(v.weight_g)}"></label><label>Объём, мл<input data-key="volume_ml" type="number" min="1" max="1000000" value="${esc(v.volume_ml)}"></label></div><label class="check"><input data-key="active" type="checkbox" ${v.active?'checked':''}>В продаже</label></div>`).join('');
  form.elements.stock.readOnly=rows.length>0;form.elements.price_uzs.readOnly=rows.length>0;
 }
 panel.querySelector('#new-variant').onclick=()=>{if(busy||rows.length>=100)return;rows=readVariantEditor(form);rows.push({name:'',price_uzs:0,stock:0,active:true});render();};render();
}
function readVariantEditor(form){return [...form.querySelectorAll('[data-variant-row]')].map(row=>{
 const result={};if(row.dataset.id)result.id=row.dataset.id;
 for(const name of ['name','price_uzs','stock','weight_g','volume_ml','active']){
  const input=row.querySelector(`[data-key="${name}"]`);result[name]=name==='active'?input.checked:name==='name'?input.value:input.value===''?null:Number(input.value);
 }return result;
});}
function recommendationsEditor(form,product){
  let selected=[...(product.recommendation_ids||[])];
  const panel=document.createElement('section');panel.className='full';
  panel.innerHTML='<h2>Рекомендуемые товары</h2><p>До 10 товаров своего заведения. Порядок можно менять; скрытые и отсутствующие товары клиентам не показываются.</p><input type="hidden" name="recommendation_ids"><label>Поиск по своему каталогу<input type="search" id="recommendation-search" maxlength="160"></label><div id="recommendation-selected"></div><div id="recommendation-options"></div>';
  form.lastElementChild.before(panel);
  const hidden=panel.querySelector('[name="recommendation_ids"]'),search=panel.querySelector('#recommendation-search');
  function render(){
    hidden.value=JSON.stringify(selected);
    panel.querySelector('#recommendation-selected').innerHTML=selected.map((id,index)=>{
      const p=products.find(p=>p.id===id);
      return `<div class="card row"><span>${index+1}. ${esc(p?.name||'Товар недоступен')}</span><span><button type="button" data-up="${id}" ${index===0?'disabled':''}>↑</button><button type="button" data-down="${id}" ${index===selected.length-1?'disabled':''}>↓</button><button type="button" data-remove="${id}">Убрать</button></span></div>`;
    }).join('');
    const query=search.value.trim().normalize('NFKC').toLocaleLowerCase();
    panel.querySelector('#recommendation-options').innerHTML=products.filter(p=>p.id!==product.id&&!selected.includes(p.id)&&p.active&&p.stock>0&&p.name.normalize('NFKC').toLocaleLowerCase().includes(query)).slice(0,50).map(p=>`<button type="button" class="secondary" data-recommend="${p.id}" ${selected.length>=10?'disabled':''}>+ ${esc(p.name)}</button>`).join('');
    panel.querySelectorAll('[data-recommend]').forEach(b=>{b.onclick=()=>{if(busy||selected.length>=10)return;const id=Number(b.dataset.recommend);if(!selected.includes(id))selected.push(id);render();};});
    panel.querySelectorAll('[data-remove]').forEach(b=>{b.onclick=()=>{if(busy)return;selected=selected.filter(id=>id!==Number(b.dataset.remove));render();};});
    for(const direction of ['up','down'])panel.querySelectorAll(`[data-${direction}]`).forEach(b=>{b.onclick=()=>{if(busy)return;const i=selected.indexOf(Number(b.dataset[direction])),j=i+(direction==='up'?-1:1);if(i>=0&&j>=0&&j<selected.length){[selected[i],selected[j]]=[selected[j],selected[i]];render();}};});
  }
  search.oninput=()=>{if(!busy)render();};render();
}
function destinationDetails(d){return [['entrance','Подъезд'],['floor','Этаж'],['apartment','Квартира'],['landmark','Ориентир']].filter(([key])=>d[key]).map(([key,label])=>label+': '+esc(d[key])).join(' · ');}
function cashHistory(o){
 if(o.cash_model!=='courier_buyout_v1')return '';
 const names={shop_paid:'Курьер подтвердил оплату магазину',shop_received:'Магазин подтвердил получение денег',client_arrived:'Курьер у получателя',client_cash:'Наличные клиента получены',completed:'Завершение подтверждено'};
 return '<p><b>'+esc(o.environment==='TEST'?'TEST · тестовые суммы':'Наличные: курьер оплачивает товары')+'</b></p><ul>'+o.cash.events.map(e=>'<li>'+esc(names[e.kind]||e.kind)+' · '+money(e.amount_uzs)+'</li>').join('')+'</ul>';
}
function ordersView() {
  main.innerHTML = '<div class="row"><h1>Заказы</h1><button id="refresh" class="secondary">Обновить</button></div>' + (orders.length ? orders.map(o => `<article class="card"><div class="row"><b>${esc(o.shop_name)}</b><span class="badge">${esc(statusNames[o.status] || o.status)}</span></div><p class="mono">${esc(o.id)}</p><p>${o.items.map(i => `${esc(i.name)}${i.variant_name?' · '+esc(i.variant_name):''} × ${i.quantity}`).join('<br>')}</p><p>${esc(o.destination.address)}<br>${destinationDetails(o.destination)}<br>${esc(o.phone)}</p><div class="row"><span class="muted">Товары ${money(o.subtotal_uzs)} · Доставка ${money(o.delivery_uzs)}</span><b class="price">${money(o.total_uzs)}</b></div>${cashHistory(o)}${me.role === 'partner' ? `<div class="actions">${o.cash?.shop_paid && !o.cash.shop_received && ['assigned','accepted'].includes(o.status) ? `<button data-order="${o.id}" data-action="cash_received">Получены наличные от курьера: ${money(o.subtotal_uzs)}</button>` : ''}${o.status === 'pending_shop' ? `<button data-order="${o.id}" data-action="confirm">Подтвердить</button><button class="danger" data-order="${o.id}" data-action="reject">Отказать</button>` : ['confirmed','assigned','accepted'].includes(o.status) && !o.ready_at ? `<button data-order="${o.id}" data-action="ready">Готов к выдаче</button>` : ''}</div>` : ''}</article>`).join('') : empty('Заказов пока нет.'));
  document.querySelector('#refresh').onclick = () => perform(() => show('orders'));
  if (me.role === 'admin') {
    const panel = document.createElement('section');
    const phases = { queued:'Ожидает назначения', creating:'Создаётся в TaxiMaster', uncertain:'Проверяется результат создания', bound:'Связан с TaxiMaster', blocked:'Назначение отклонено', review:'Нужна проверка диспетчера' };
    panel.innerHTML = '<h2>Назначение курьеров</h2>' + (transport.enabled ? orders.filter(o => ['pending_shop','confirmed','ready','assigned','accepted','picked_up'].includes(o.status)).map(o => {
      const job = transport.jobs.find(j => j.order_id === o.id);
      const actions=management.filter(a=>a.order_id===o.id),pending=actions.find(a=>['queued','sending','uncertain','review'].includes(a.phase)),last=actions[0];
      const allowed=!o.cash?.shop_paid && !pending && ['pending_shop','confirmed','ready','assigned','accepted'].includes(o.status) && (!job || ['queued','blocked','bound'].includes(job.phase));
      return `<article class="card"><b>${esc(o.shop_name)}</b><p class="mono">${esc(o.id)}</p>${job ? `<p>${esc(phases[job.phase] || job.phase)}${job.transport_order_id ? ' · TaxiMaster ' + job.transport_order_id : ''}</p>${job.last_error ? '<p>Проверьте назначение в TaxiMaster. Повторное создание заблокировано до выяснения результата.</p>' : ''}` : ['confirmed','ready'].includes(o.status)?`<button data-dispatch="${o.id}">Назначить курьера</button>`:''}${pending?'<p role="status">Проверяем отмену прежней перевозки в TaxiMaster. Новое назначение пока заблокировано.</p>':last?.phase==='blocked'?'<p>Действие отклонено. Проверьте состояние, готовность и штраф за отмену в TaxiMaster.</p>':''}${allowed?`<div class="actions"><button class="danger" data-manage="${o.id}" data-operation="cancel">Отменить доставку</button>${job && o.status!=='pending_shop'?`<button class="secondary" data-manage="${o.id}" data-operation="reassign">Другой курьер</button>`:''}</div>`:''}</article>`;
    }).join('') : '<p class="muted">Связь доставки с TaxiMaster пока не включена.</p>');
    main.append(panel);
    panel.querySelectorAll('[data-manage]').forEach(button=>{button.onclick=()=>perform(()=>managementForm(orders.find(o=>o.id===button.dataset.manage),button.dataset.operation));});
    panel.querySelectorAll('[data-dispatch]').forEach(button => { button.onclick = () => perform(async () => {
      const o = orders.find(o => o.id === button.dataset.dispatch), available = await request('/admin/transport-options');
      main.innerHTML = `<h1>Назначить курьера</h1><p>${esc(o.shop_name)} → ${esc(o.destination.address)}</p><p>Наличные от клиента: ${money(o.total_uzs)}. Перевозка в TaxiMaster: ${money(o.delivery_uzs)}.</p><form id="dispatch-form">${choose('crew_id','Свободный экипаж на линии',available.crews)}${choose('tariff_id','Тариф подтверждённого расчёта',available.tariffs.filter(t=>!o.delivery_tariff_id||t.id===o.delivery_tariff_id),o.delivery_tariff_id)}<div class="full"><button>Назначить</button><button type="button" id="back" class="secondary">Назад</button></div></form>`;
      document.querySelector('#back').onclick = () => perform(() => show('orders'));
      document.querySelector('#dispatch-form').onsubmit = event => { event.preventDefault(); const input = Object.fromEntries(new FormData(event.currentTarget)); input.crew_id = Number(input.crew_id); input.tariff_id = Number(input.tariff_id); input.version = o.version;
        perform(async () => { await request(`/admin/orders/${o.id}/dispatch`, { method:'POST', body:input, key:commandKey(o, 'dispatch-' + input.crew_id + '-' + input.tariff_id) }); await show('orders'); });
      };
    }); });
  }
  main.querySelectorAll('[data-order]').forEach(b => { b.onclick = () => {
    const o = orders.find(o => o.id === b.dataset.order), action = b.dataset.action;
    const reason = action === 'reject' ? prompt('Причина отказа:') : undefined;
    if (action === 'reject' && !reason?.trim()) return;
    perform(async () => { await request(`/merchant/orders/${o.id}/action`, { method:'POST', body:{ action, version:o.version, ...(reason ? { reason:reason.trim() } : {}) }, key:commandKey(o, action) }); await show('orders'); });
  }; });
}
async function managementForm(order,action){
  const job=transport.jobs.find(j=>j.order_id===order.id),bound=!!job?.transport_order_id;
  const available=(bound||action==='reassign')?await request('/admin/transport-options'):{crews:[],tariffs:[],cancel_states:[]};
  main.innerHTML=`<h1>${action==='cancel'?'Отменить доставку':'Назначить другого курьера'}</h1><p>${esc(order.shop_name)} → ${esc(order.destination.address)}</p><p>${bound?'Прежняя перевозка будет отменена только при нулевом штрафе. Дождитесь подтверждения TaxiMaster.':''}${action==='reassign'?' Товар останется в резерве. Новое назначение появится после подтверждённой отмены прежнего.':''}</p><form id="management-form">${action==='reassign'?choose('crew_id','Новый свободный экипаж',available.crews.filter(c=>c.id!==job.crew_id))+choose('tariff_id','Тариф подтверждённого расчёта',available.tariffs.filter(t=>!order.delivery_tariff_id||t.id===order.delivery_tariff_id),job.tariff_id):''}${bound?choose('cancel_state_id','Причина отмены в TaxiMaster',available.cancel_states,available.cancel_states.length===1?available.cancel_states[0].id:undefined):''}${field('reason','Комментарий диспетчера','','text','maxlength="300"')}<div class="full"><button>Подтвердить</button><button type="button" id="management-back" class="secondary">Назад</button></div></form>`;
  document.querySelector('#management-back').onclick=()=>perform(()=>show('orders'));
  document.querySelector('#management-form').onsubmit=event=>{
    event.preventDefault();const input=Object.fromEntries(new FormData(event.currentTarget));input.action=action;input.version=order.version;
    for(const name of ['crew_id','tariff_id','cancel_state_id'])if(input[name]!=null)input[name]=Number(input[name]);
    perform(async()=>{await request(`/admin/orders/${order.id}/manage`,{method:'POST',body:input,key:commandKey(order,'manage-'+action+'-'+(input.crew_id||0)+'-'+(input.tariff_id||0)+'-'+(input.cancel_state_id||0))});await show('orders');});
  };
}
function financeView(rows) {
  main.innerHTML = '<h1>Финансовая сводка</h1><p>Данные по доставленным заказам. Записи показывают собранные наличные и обязательства; фактические выплаты отражаются отдельно.</p>' + (rows.length ? '<div class="card tablewrap"><table><thead><tr><th>Показатель</th><th>Заказов</th><th>Сумма</th></tr></thead><tbody>' + rows.map(r => `<tr><td>${esc(financeNames[r.kind] || r.kind)}</td><td>${r.entries}</td><td>${money(Math.abs(r.amount_uzs))}</td></tr>`).join('') + '</tbody></table></div>' : empty('Пока нет завершённых доставок.'));
}
loginView();
