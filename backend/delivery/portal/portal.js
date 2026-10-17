const main = document.querySelector('#main'), tabs = document.querySelector('#tabs'), notice = document.querySelector('#notice'), account = document.querySelector('#account');
let token = '', me = null, tab = '', busy = false, config = null, products = [], orders = [], timer = null, transport = { enabled:false, jobs:[] }, management=[];
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = v => Number(v || 0).toLocaleString('ru-RU') + ' сум';
const statusNames = { pending_shop: 'Новый заказ', confirmed: 'Подтверждён магазином', ready: 'Готов к выдаче', assigned: 'Курьер назначен', accepted: 'Курьер принял', picked_up: 'Товар у курьера', completed: 'Доставлен', cancelled: 'Отменён', rejected: 'Магазин отказал' };
const financeNames = { driver_cash_receivable: 'Наличные у курьеров', courier_payable: 'К выплате курьерам', merchant_payable: 'К выплате магазинам', service_revenue: 'Комиссия службы' };
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
  const sections = me.role === 'admin' ? [['shops','Магазины'],['categories','Категории'],['zones','Тарифы и зоны'],['orders','Заказы'],['finance','Финансы']] : [['products','Товары'],['orders','Заказы'],['finance','Финансы']];
  tabs.innerHTML = sections.map(([id, title]) => `<button data-tab="${id}" class="${id === tab ? 'selected' : ''}">${title}</button>`).join('');
  tabs.querySelectorAll('button').forEach(button => { button.onclick = () => perform(() => show(button.dataset.tab)); });
  if (me.role === 'admin') config = await request('/admin/config');
  if (tab === 'shops') shopsView();
  else if (tab === 'categories') categoriesView();
  else if (tab === 'zones') zonesView();
  else if (tab === 'products') { products = await request('/merchant/products'); productsView(); }
  else if (tab === 'orders') { orders = await request(me.role === 'admin' ? '/admin/orders' : '/merchant/orders'); if (me.role === 'admin') { transport = await request('/admin/transport'); management=await request('/admin/management'); } ordersView(); }
  else if (tab === 'finance') financeView(await request(me.role === 'admin' ? '/admin/finance' : '/merchant/finance'));
}
function shopsView() {
  main.innerHTML = '<h1>Магазины</h1><button id="new-shop">Добавить магазин</button><div style="height:16px"></div>' + config.shops.map(s => `<article class="card"><div class="row"><b>${esc(s.name)}</b><span class="badge">${s.active ? 'Работает' : 'Отключён'}</span></div><p>${esc(s.address)}</p><div class="muted">Комиссия ${s.commission_bps / 100}%</div><div class="actions"><button data-shop="${s.id}" class="secondary">Изменить</button></div></article>`).join('');
  document.querySelector('#new-shop').onclick = () => shopForm();
  main.querySelectorAll('[data-shop]').forEach(b => { b.onclick = () => shopForm(config.shops.find(s => s.id === Number(b.dataset.shop))); });
}
function shopForm(shop) {
  if (!config.categories.length || !config.zones.length) { notice.textContent = 'Сначала добавьте категорию и зону доставки.'; return; }
  const s = shop || {};
  main.innerHTML = `<h1>${shop ? 'Изменить магазин' : 'Новый магазин'}</h1><form id="shop-form">${field('name','Название',s.name)}${field('address','Адрес',s.address)}${field('lat','Широта',s.lat,'number','step="any" min="-90" max="90"')}${field('lon','Долгота',s.lon,'number','step="any" min="-180" max="180"')}${choose('category_id','Категория',config.categories,s.category_id)}${choose('zone_id','Зона доставки',config.zones,s.zone_id)}${field('commission','Комиссия магазина, %',shop ? s.commission_bps / 100 : '','number','min="0" max="100" step="0.01"')}${shop ? check('active','Магазин активен',s.active) : field('login','Логин партнёра','','text','autocomplete="off" minlength="3"') + field('password','Первый пароль партнёра','','password','autocomplete="new-password" minlength="12"')}<div class="full"><button>Сохранить</button><button type="button" class="secondary" id="back">Назад</button></div></form>`;
  document.querySelector('#back').onclick = shopsView;
  document.querySelector('#shop-form').onsubmit = event => { event.preventDefault(); const form = event.currentTarget; perform(async () => {
    const input = Object.fromEntries(new FormData(form)); for (const key of ['lat','lon','category_id','zone_id']) input[key] = Number(input[key]); input.commission_bps = Math.round(Number(input.commission) * 100); delete input.commission;
    if (shop) input.active = form.elements.active.checked;
    await request(shop ? '/admin/shops/' + s.id : '/admin/shops', { method: shop ? 'PUT' : 'POST', body: input }); await show('shops');
  }); };
}
function categoriesView() {
  main.innerHTML = '<h1>Категории</h1><form id="category-form">' + field('name','Название категории') + '<button>Добавить категорию</button></form>' + config.categories.map(c => `<div class="card row"><b>${esc(c.name)}</b><button class="secondary" data-category="${c.id}">${c.active ? 'Отключить' : 'Включить'}</button></div>`).join('');
  document.querySelector('#category-form').onsubmit = event => { event.preventDefault(); const name = event.currentTarget.elements.name.value; perform(async () => { await request('/admin/categories', { method:'POST', body:{ name, active:true } }); await show('categories'); }); };
  main.querySelectorAll('[data-category]').forEach(b => { b.onclick = () => perform(async () => { const c = config.categories.find(c => c.id === Number(b.dataset.category)); await request('/admin/categories/' + c.id, { method:'PUT', body:{ name:c.name, active:!c.active } }); await show('categories'); }); });
}
function zonesView() {
  main.innerHTML = '<h1>Тарифы и зоны</h1><p>Стоимость доставки: базовая сумма плюс цена за каждый начатый километр прямого расстояния от магазина. Границы ограничивают доступные адреса.</p><button id="new-zone">Добавить зону</button><div style="height:16px"></div>' + config.zones.map(z => `<article class="card"><div class="row"><b>${esc(z.name)}</b><button class="secondary" data-zone="${z.id}">Изменить</button></div><p>${money(z.base_uzs)} + ${money(z.per_km_uzs)}/км · максимум ${z.max_distance_m} м · ${z.active ? 'активна' : 'отключена'}</p></article>`).join('');
  document.querySelector('#new-zone').onclick = () => zoneForm();
  main.querySelectorAll('[data-zone]').forEach(b => { b.onclick = () => zoneForm(config.zones.find(z => z.id === Number(b.dataset.zone))); });
}
function zoneForm(zone) {
  const z = zone || {};
  main.innerHTML = '<h1>Зона доставки</h1><form id="zone-form">' + field('name','Название',z.name) + [['south','Южная широта'],['north','Северная широта'],['west','Западная долгота'],['east','Восточная долгота']].map(([name,label]) => field(name,label,z[name],'number','step="any"')).join('') + [['base_uzs','Базовая стоимость, сум'],['per_km_uzs','За начатый километр, сум'],['max_distance_m','Максимальное расстояние, м']].map(([name,label]) => field(name,label,z[name],'number','min="0" step="1"')).join('') + check('active','Зона активна',zone ? z.active : true) + '<div class="full"><button>Сохранить</button></div></form>';
  document.querySelector('#zone-form').onsubmit = event => { event.preventDefault(); const form = event.currentTarget; perform(async () => { const input = Object.fromEntries(new FormData(form)); for (const key of ['south','north','west','east','base_uzs','per_km_uzs','max_distance_m']) input[key] = Number(input[key]); input.active = form.elements.active.checked; await request('/admin/zones' + (zone ? '/' + z.id : ''), { method:zone ? 'PUT' : 'POST', body:input }); await show('zones'); }); };
}
function productsView() {
  main.innerHTML = '<h1>Товары</h1><button id="new-product">Добавить товар</button><div style="height:16px"></div>' + (products.length ? products.map(p => `<article class="card"><div class="row"><div class="product-title">${p.image_id ? `<img class="thumb" src="/api/delivery/images/${esc(p.image_id)}" alt="">` : ''}<b>${esc(p.name)}</b></div><button class="secondary" data-product="${p.id}">Изменить</button></div><p>${money(p.price_uzs)} · Остаток: ${p.stock} · ${p.active ? 'В продаже' : 'Скрыт'}</p></article>`).join('') : empty('Добавьте первый товар и фотографию.'));
  document.querySelector('#new-product').onclick = () => productForm();
  main.querySelectorAll('[data-product]').forEach(b => { b.onclick = () => productForm(products.find(p => p.id === Number(b.dataset.product))); });
}
function productForm(product) {
  const p = product || {}; let imageId = p.image_id || null;
  main.innerHTML = `<h1>${product ? 'Изменить товар' : 'Новый товар'}</h1><form id="product-form">${field('sku','Артикул',p.sku)}${field('name','Название',p.name)}<label class="full">Описание<textarea name="description" maxlength="2000">${esc(p.description)}</textarea></label>${field('price_uzs','Цена, сум',p.price_uzs,'number','min="0" max="10000000" step="1"')}${field('stock','Доступно, шт.',p.stock,'number','min="0" max="1000000" step="1"')}<label>Фотография (PNG, JPEG, WebP; до 2 МБ)<input name="photo" type="file" accept="image/png,image/jpeg,image/webp"></label>${check('active','В продаже',product ? p.active : true)}<div class="full"><button>Сохранить</button><button id="back" class="secondary" type="button">Назад</button></div></form>`;
  document.querySelector('#back').onclick = () => perform(() => show('products'));
  document.querySelector('#product-form').onsubmit = event => { event.preventDefault(); const form = event.currentTarget; perform(async () => {
    const input = Object.fromEntries(new FormData(form)), file = input.photo;
    if (file?.size) { if (file.size > 2 * 1024 * 1024) throw new Error('Фото должно быть меньше 2 МБ'); imageId = (await request('/merchant/images', { method:'POST', body:file, raw:true })).id; form.elements.photo.value = ''; }
    delete input.photo; input.price_uzs = Number(input.price_uzs); input.stock = Number(input.stock); input.active = form.elements.active.checked; input.image_id = imageId; if (product) input.version = p.version;
    await request('/merchant/products' + (product ? '/' + p.id : ''), { method:product ? 'PUT' : 'POST', body:input }); await show('products');
  }); };
}
function ordersView() {
  main.innerHTML = '<div class="row"><h1>Заказы</h1><button id="refresh" class="secondary">Обновить</button></div>' + (orders.length ? orders.map(o => `<article class="card"><div class="row"><b>${esc(o.shop_name)}</b><span class="badge">${esc(statusNames[o.status] || o.status)}</span></div><p class="mono">${esc(o.id)}</p><p>${o.items.map(i => `${esc(i.name)} × ${i.quantity}`).join('<br>')}</p><p>${esc(o.destination.address)}<br>${esc(o.phone)}</p><div class="row"><span class="muted">Товары ${money(o.subtotal_uzs)} · Доставка ${money(o.delivery_uzs)}</span><b class="price">${money(o.total_uzs)}</b></div>${me.role === 'partner' ? `<div class="actions">${o.status === 'pending_shop' ? `<button data-order="${o.id}" data-action="confirm">Подтвердить</button><button class="danger" data-order="${o.id}" data-action="reject">Отказать</button>` : ['confirmed','assigned','accepted'].includes(o.status) && !o.ready_at ? `<button data-order="${o.id}" data-action="ready">Готов к выдаче</button>` : ''}</div>` : ''}</article>`).join('') : empty('Заказов пока нет.'));
  document.querySelector('#refresh').onclick = () => perform(() => show('orders'));
  if (me.role === 'admin') {
    const panel = document.createElement('section');
    const phases = { queued:'Ожидает назначения', creating:'Создаётся в TaxiMaster', uncertain:'Проверяется результат создания', bound:'Связан с TaxiMaster', blocked:'Назначение отклонено', review:'Нужна проверка диспетчера' };
    panel.innerHTML = '<h2>Назначение курьеров</h2>' + (transport.enabled ? orders.filter(o => ['pending_shop','confirmed','ready','assigned','accepted','picked_up'].includes(o.status)).map(o => {
      const job = transport.jobs.find(j => j.order_id === o.id);
      const actions=management.filter(a=>a.order_id===o.id),pending=actions.find(a=>['queued','sending','uncertain','review'].includes(a.phase)),last=actions[0];
      const allowed=!pending && ['pending_shop','confirmed','ready','assigned','accepted'].includes(o.status) && (!job || ['queued','blocked','bound'].includes(job.phase));
      return `<article class="card"><b>${esc(o.shop_name)}</b><p class="mono">${esc(o.id)}</p>${job ? `<p>${esc(phases[job.phase] || job.phase)}${job.transport_order_id ? ' · TaxiMaster ' + job.transport_order_id : ''}</p>${job.last_error ? '<p>Проверьте назначение в TaxiMaster. Повторное создание заблокировано до выяснения результата.</p>' : ''}` : ['confirmed','ready'].includes(o.status)?`<button data-dispatch="${o.id}">Назначить курьера</button>`:''}${pending?'<p role="status">Проверяем отмену прежней перевозки в TaxiMaster. Новое назначение пока заблокировано.</p>':last?.phase==='blocked'?'<p>Действие отклонено. Проверьте состояние, готовность и штраф за отмену в TaxiMaster.</p>':''}${allowed?`<div class="actions"><button class="danger" data-manage="${o.id}" data-operation="cancel">Отменить доставку</button>${job && o.status!=='pending_shop'?`<button class="secondary" data-manage="${o.id}" data-operation="reassign">Другой курьер</button>`:''}</div>`:''}</article>`;
    }).join('') : '<p class="muted">Связь доставки с TaxiMaster пока не включена.</p>');
    main.append(panel);
    panel.querySelectorAll('[data-manage]').forEach(button=>{button.onclick=()=>perform(()=>managementForm(orders.find(o=>o.id===button.dataset.manage),button.dataset.operation));});
    panel.querySelectorAll('[data-dispatch]').forEach(button => { button.onclick = () => perform(async () => {
      const o = orders.find(o => o.id === button.dataset.dispatch), available = await request('/admin/transport-options');
      main.innerHTML = `<h1>Назначить курьера</h1><p>${esc(o.shop_name)} → ${esc(o.destination.address)}</p><p>Наличные от клиента: ${money(o.total_uzs)}. Перевозка в TaxiMaster: ${money(o.delivery_uzs)}.</p><form id="dispatch-form">${choose('crew_id','Свободный экипаж на линии',available.crews)}${choose('tariff_id','Тариф TaxiMaster',available.tariffs)}<div class="full"><button>Назначить</button><button type="button" id="back" class="secondary">Назад</button></div></form>`;
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
  main.innerHTML=`<h1>${action==='cancel'?'Отменить доставку':'Назначить другого курьера'}</h1><p>${esc(order.shop_name)} → ${esc(order.destination.address)}</p><p>${bound?'Прежняя перевозка будет отменена только при нулевом штрафе. Дождитесь подтверждения TaxiMaster.':''}${action==='reassign'?' Товар останется в резерве. Новое назначение появится после подтверждённой отмены прежнего.':''}</p><form id="management-form">${action==='reassign'?choose('crew_id','Новый свободный экипаж',available.crews.filter(c=>c.id!==job.crew_id))+choose('tariff_id','Тариф TaxiMaster',available.tariffs,job.tariff_id):''}${bound?choose('cancel_state_id','Причина отмены в TaxiMaster',available.cancel_states,available.cancel_states.length===1?available.cancel_states[0].id:undefined):''}${field('reason','Комментарий диспетчера','','text','maxlength="300"')}<div class="full"><button>Подтвердить</button><button type="button" id="management-back" class="secondary">Назад</button></div></form>`;
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
