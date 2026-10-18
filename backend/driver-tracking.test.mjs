import test from 'node:test';
import assert from 'node:assert/strict';
import { driverTracking,taxiCoordinateEpoch } from './driver-tracking.mjs';
const now=Date.parse('2026-10-18T07:00:00Z'),state={crew_id:4},location={crew_id:4,lat:40,lon:65,coords_time:'20261018115930'};
test('tracking uses configured TM timezone, real coordinate age and exact crew',()=>{
 assert.equal(taxiCoordinateEpoch('20261018120000','Asia/Tashkent'),now);
 assert.equal(taxiCoordinateEpoch('20261018070000','UTC'),now);
 const r=driverTracking(state,location,{now,timeZone:'Asia/Tashkent'});assert.equal(r.location_age_seconds,30);assert.equal(r.available,true);assert.equal(r.source,'TaxiMaster');
 for(const changes of [{crew_id:5},{lat:NaN},{lon:181},{coords_time:'20261018115759'},{coords_time:'20261018120001'},{coords_time:null}])assert.equal(driverTracking(state,{...location,...changes},{now,timeZone:'Asia/Tashkent'}).available,false);
 assert.equal(driverTracking(state,{...location,coords_time:'20261018115800'},{now,timeZone:'Asia/Tashkent'}).available,true);
});
test('invalid dates/timezones and ambiguous DST coordinates fail closed',()=>{
 for(const raw of ['20260230120000','20261018240000','20261301120000','20261018126000','bad',null,123])assert.equal(taxiCoordinateEpoch(raw,'Asia/Tashkent'),null);
 assert.equal(taxiCoordinateEpoch('20261018120000','Invalid/Zone'),null);
 assert.equal(taxiCoordinateEpoch('20261018120000',undefined),null);
 assert.equal(taxiCoordinateEpoch('20261025023000','Europe/Berlin'),null);
 assert.equal(taxiCoordinateEpoch('20260329023000','Europe/Berlin'),null);
});
