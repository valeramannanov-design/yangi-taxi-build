/** Real CommonAPI adapter; injected host functions retain existing signing/TLS.
 * Reference: https://help.taximaster.ru/index.php/TM_API */
export function createTaxiMasterDeliveryAdapter({ get, post, postQuery, catalog, time, phone, allowedCrews=null, allowedDrivers=null }) {
  const allowed=(crew,driver)=>(allowedCrews===null || allowedCrews.includes(crew)) && (allowedDrivers===null || allowedDrivers.includes(driver));
  const read = order_id => get('get_order_state', { order_id });
  return {
    async options() {
      const [working, current, definitions, states] = await Promise.all([get('get_crews_info'), get('get_current_orders'), catalog(), get('get_order_states_list')]);
      if (!Array.isArray(working.crews_info) || !Array.isArray(current.orders)) throw new Error('Invalid TaxiMaster fleet response');
      const occupied = new Set(current.orders.flatMap(o => ['c' + o.crew_id, 'd' + o.driver_id]));
      return {
        crews: working.crews_info.filter(c => c.online === true && c.driver_id > 0 && allowed(c.crew_id,c.driver_id) && !occupied.has('c' + c.crew_id) && !occupied.has('d' + c.driver_id)).map(c => ({ id: c.crew_id, name: c.name || c.code || String(c.crew_id) })),
        tariffs: [...definitions.tariffs.entries()].filter(([, t]) => t.is_active === true).map(([id, t]) => ({ id, name: t.name || String(id) })),
        cancel_states:(states.order_states||[]).filter(s=>s.state_type==='aborted').map(s=>({id:s.id,name:s.name})),
      };
    },
    async prepare(job, order, snapshot) {
      const crew = await get('get_crew_info', { crew_id: job.crew_id });
      if(!allowed(crew.crew_id,crew.driver_id))throw new Error('Courier is outside enabled Delivery scope');
      if(snapshot.delivery_tariff_id && (snapshot.delivery_tariff_id!==job.tariff_id || snapshot.delivery_crew_group_id!==crew.crew_group_id))throw new Error('Courier group or tariff differs from the confirmed route quote');
      if (crew.crew_id !== job.crew_id || crew.online !== true || !Number.isSafeInteger(crew.driver_id) || crew.driver_id < 1) throw new Error('Courier unavailable');
      const [driver, working, current, definitions] = await Promise.all([
        get('get_driver_info', { driver_id: crew.driver_id, fields: 'driver_id,is_locked,is_dismissed' }),
        get('get_crews_info', { fields: 'crew_id,driver_id' }),
        get('get_current_orders', { driver_id: crew.driver_id }), catalog(),
      ]);
      if (driver.driver_id !== crew.driver_id || driver.is_locked !== false || driver.is_dismissed !== false || !working.crews_info?.some(c => c.crew_id === crew.crew_id && c.driver_id === crew.driver_id) || !Array.isArray(current.orders) || current.orders.length) throw new Error('Courier not idle on line');
      if (!definitions.groups.has(crew.crew_group_id) || definitions.tariffs.get(job.tariff_id)?.is_active !== true) throw new Error('Inactive tariff or unknown group');
      const client = Number(order.customer_id);
      if (!Number.isSafeInteger(client) || client < 1) throw new Error('Invalid TaxiMaster client');
      return { driver_id: crew.driver_id, body: { client_id: client, phone: phone(snapshot.phone), customer: job.marker,
        comment: 'Yangi Delivery', addresses: [snapshot.pickup, snapshot.destination],
        source_time: time(), is_prior: false, check_duplicate: true, need_custom_validate: true,
        crew_id: crew.crew_id, crew_group_id: crew.crew_group_id, tariff_id: job.tariff_id,
        total_cost: snapshot.delivery_uzs, cost_freeze: true,
        use_cashless: false, use_bonus: false, cashless_sum: 0, bonus_sum: 0 } };
    },
    create: body => post('create_order2', body), read,
    async prepareCancel(job,stateId) {
      if(typeof postQuery!=='function')throw new Error('Cancellation adapter unavailable');
      const states=await get('get_order_states_list');
      if(!states.order_states?.some(s=>s.id===stateId && s.state_type==='aborted'))throw new Error('Unknown cancellation state');
      const penalty=await get('check_cancel_order_penalty',{order_id:job.transport_order_id,cancel_order_state_id:stateId});
      const amount=penalty.cancel_order_penalty_sum;
      if(!['number','string'].includes(typeof amount) || typeof amount==='string'&&!/^[0-9]+(?:\.[0-9]+)?$/.test(amount) || Number(amount)!==0)throw new Error('Cancellation has a fee; dispatcher review required');
      return {order_id:job.transport_order_id,new_state:stateId,cancel_order_penalty_sum:0};
    },
    cancel:plan=>{if(typeof postQuery!=='function')throw new Error('Cancellation adapter unavailable');return postQuery('change_order_state',plan);},
    async find(job, order) {
      // No time-limited archive assumptions. Missing/expired orders stay unresolved
      // for dispatcher review; an unresolved job never permits another creation.
      const data = await get('get_current_orders', { client_id: Number(order.customer_id) });
      if (!Array.isArray(data.orders)) throw new Error('Invalid TaxiMaster order list');
      const candidates = data.orders.filter(o => o.customer === job.marker);
      return Promise.all(candidates.map(o => read(Number(o.order_id || o.id))));
    },
  };
}
