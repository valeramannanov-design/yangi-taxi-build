import { resolve, dirname, basename } from 'node:path';
import { tmpdir } from 'node:os';
const permits=new WeakMap();
// No HTTP/config flag can issue a permit. Only Node tests or the dedicated
// loopback test host with an ephemeral temp database may construct TEST mode.
export function isolatedTestPermit(path) {
  const testing=!!process.env.NODE_TEST_CONTEXT || process.env.NODE_ENV==='test' && process.env.GO_ISOLATED_TEST==='1';
  const valid=path===':memory:' || dirname(resolve(path))===resolve(tmpdir()) && basename(path).startsWith('yangi-go-test-');
  if(!testing || !valid)throw new Error('TEST adapter requires an isolated temporary database and test runtime');
  const permit=Object.freeze({label:'TEST'});permits.set(permit,path);return permit;
}
export function isTestIsolation(permit,path){return permits.has(permit)&&permits.get(permit)===path;}
