import test from 'node:test';
import assert from 'node:assert/strict';
import { createTaxiMasterDeliveryAdapter } from './tm-adapter.mjs';

function fixture(scope={}) {
  const calls = [], records = {
    get_crew_info: { crew_id: 4, driver_id: 5, crew_group_id: 8, online: true },
    get_driver_info: { driver_id: 5, is_locked: false, is_dismissed: false },
    get_crews_info: { crews_info: [{ crew_id: 4, driver_id: 5 }] },
    get_current_orders: { orders: [] },
    get_order_states_list:{order_states:[{id:88,name:'Cancelled from server',state_type:'aborted'}]},
    check_cancel_order_penalty:{cancel_order_penalty_sum:0},
    get_order_state: { order_id: 90, customer: 'YANGI_DELIVERY/abc' },
  };
  const adapter = createTaxiMasterDeliveryAdapter({
    ...scope,
    get: async (name, params) => { calls.push({ name, params }); return records[name]; },
    post: async (name, body) => { calls.push({ name, body }); return { order_id: 90 }; },
    postQuery:async(name,body)=>{calls.push({name,body});return {};},
    catalog: async () => ({ groups: new Map([[8, {}]]), tariffs: new Map([[9, { is_active: true }]]) }),
    phone: p => p.replace(/\D/g, ''), time: () => '20261017120000',
  });
  const job = { crew_id: 4, tariff_id: 9, marker: 'YANGI_DELIVERY/abc' };
  const order = { customer_id: '101' };
  const snapshot = { phone: '+998900000001', pickup: { address: 'Store', lat: 40, lon: 65 }, destination: { address: 'Customer', lat: 40.01, lon: 65 }, delivery_uzs: 6000, total_uzs: 25000 };
  return { adapter, records, calls, job, order, snapshot };
}
test('CommonAPI adapter uses real crew/group/tariff and freezes only the delivery fee', async () => {
  const f = fixture(), prepared = await f.adapter.prepare(f.job, f.order, f.snapshot);
  assert.equal(prepared.driver_id, 5);
  assert.equal(prepared.body.crew_id, 4); assert.equal(prepared.body.crew_group_id, 8);
  assert.equal(prepared.body.tariff_id, 9); assert.equal(prepared.body.total_cost, 6000);
  assert.equal(prepared.body.need_custom_validate, true); assert.equal(prepared.body.cost_freeze, true);
  assert.equal(prepared.body.customer, f.job.marker);
  assert.equal(prepared.body.driver_id, undefined);
  await f.adapter.create(prepared.body);
  assert.equal(f.calls.at(-1).name, 'create_order2');
});

test('road quotes retain their TM tariff and crew group before any transport creation',async()=>{
  const f=fixture();f.snapshot.delivery_tariff_id=9;f.snapshot.delivery_crew_group_id=8;
  await f.adapter.prepare(f.job,f.order,f.snapshot);
  await assert.rejects(f.adapter.prepare({...f.job,tariff_id:10},f.order,f.snapshot));
  f.records.get_crew_info.crew_group_id=9;await assert.rejects(f.adapter.prepare(f.job,f.order,f.snapshot));
  assert.equal(f.calls.some(c=>c.name==='create_order2'),false);
});
test('CommonAPI adapter refuses occupied, locked, offline or off-line crews', async () => {
  for (const change of [f => f.records.get_current_orders.orders.push({ order_id: 1 }), f => { f.records.get_driver_info.is_locked = true; }, f => { f.records.get_crew_info.online = false; }, f => { f.records.get_crews_info.crews_info = []; }]) {
    const f = fixture(); change(f);
    await assert.rejects(f.adapter.prepare(f.job, f.order, f.snapshot));
    assert.ok(!f.calls.some(c => c.name === 'create_order2'));
  }
});
test('reconciliation reads only exact delivery markers and verifies each order separately', async () => {
  const f = fixture();
  f.records.get_current_orders.orders = [{ id: 90, customer: f.job.marker }, { id: 91, customer: f.job.marker + '-other' }];
  assert.equal((await f.adapter.find(f.job, f.order)).length, 1);
  assert.deepEqual(f.calls.filter(c => c.name === 'get_order_state').map(c => c.params.order_id), [90]);
});

test('admin choices exclude occupied and offline couriers and use the live tariff list', async () => {
  const f = fixture();
  f.records.get_crews_info.crews_info = [
    { crew_id: 4, driver_id: 5, online: true, name: 'Free' },
    { crew_id: 6, driver_id: 7, online: true, name: 'Occupied' },
    { crew_id: 8, driver_id: 9, online: false, name: 'Offline' },
  ];
  f.records.get_current_orders.orders = [{ crew_id: 6, driver_id: 7 }];
  const options = await f.adapter.options();
  assert.deepEqual(options.crews, [{ id: 4, name: 'Free' }]);
  assert.deepEqual(options.tariffs, [{ id: 9, name: '9' }]);
});

test('cancellation validates the real aborted state and refuses any unknown or positive fee',async()=>{
  const f=fixture(),job={transport_order_id:90};
  await assert.rejects(f.adapter.prepareCancel(job,123));
  f.records.check_cancel_order_penalty.cancel_order_penalty_sum=1000;await assert.rejects(f.adapter.prepareCancel(job,88));
  for(const amount of [null,false,'',[],{}]){f.records.check_cancel_order_penalty.cancel_order_penalty_sum=amount;await assert.rejects(f.adapter.prepareCancel(job,88));}
  f.records.check_cancel_order_penalty.cancel_order_penalty_sum=0;
  const plan=await f.adapter.prepareCancel(job,88);await f.adapter.cancel(plan);
  assert.deepEqual(f.calls.at(-1),{name:'change_order_state',body:{order_id:90,new_state:88,cancel_order_penalty_sum:0}});
});

test('restricted rollout rejects other crews/drivers before any transport write',async()=>{
  for(const scope of [{allowedCrews:[999]},{allowedDrivers:[999]}]){
    const f=fixture(scope);await assert.rejects(f.adapter.prepare(f.job,f.order,f.snapshot));assert.ok(!f.calls.some(c=>c.name==='create_order2'));
  }
  const f=fixture({allowedCrews:[4],allowedDrivers:[5]});assert.equal((await f.adapter.prepare(f.job,f.order,f.snapshot)).driver_id,5);
});

test('driver operations are real read evidence, empty results do not manufacture zero commission',async()=>{
 const f=fixture();f.records.get_driver_operations={operations:[]};
 assert.deepEqual(await f.adapter.driverOperations(5,'20261017000000','20261018000000'),[]);
 assert.equal(f.calls.at(-1).name,'get_driver_operations');
 f.records.get_driver_operations={};await assert.rejects(f.adapter.driverOperations(5,'20261017000000','20261018000000'));
 await assert.rejects(f.adapter.driverOperations(5,'bad','20261018000000'));
});

test('own delivery entrance details never become invented TaxiMaster address fields',async()=>{
 const f=fixture();f.snapshot.destination={...f.snapshot.destination,entrance:'2',floor:'3',apartment:'4',landmark:'Near park'};
 const prepared=await f.adapter.prepare(f.job,f.order,f.snapshot);
 assert.deepEqual(Object.keys(prepared.body.addresses[1]).sort(),['address','lat','lon']);
 assert.equal(f.snapshot.destination.apartment,'4');
});
