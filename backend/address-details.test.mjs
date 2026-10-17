import test from 'node:test';
import assert from 'node:assert/strict';
import { addressDetails } from './address-details.mjs';
test('shared address metadata preserves legacy/partial edits and permits explicit clearing',()=>{
 assert.deepEqual(addressDetails({}),{entrance:'',floor:'',apartment:'',landmark:''});
 assert.equal(addressDetails({floor:' 4 '},{current:{apartment:'12A'}}).apartment,'12A');
 assert.equal(addressDetails({apartment:null},{current:{apartment:'12A'}}).apartment,'');
});
test('metadata rejects objects, controls and excess input; legacy loads sanitize without failing profile',()=>{
 for(const payload of [{entrance:{}},{floor:'x'.repeat(17)},{landmark:'hello\nworld'},{apartment:5}])assert.throws(()=>addressDetails(payload),e=>e.statusCode===400);
 assert.equal(addressDetails({floor:{}},{strict:false}).floor,'');
});
