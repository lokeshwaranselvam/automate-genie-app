import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const listeners = {};
const stores = new Map();
let offline = false;
const self = {location: {href: 'https://erp.example.test/genie/pwa-sw.js'}, clients: {claim: async () => {}}, addEventListener: (type, fn) => listeners[type] = fn};
const caches = {open: async name => { if (!stores.has(name)) stores.set(name, new Map()); const store = stores.get(name); return {addAll: async urls => urls.forEach(url => store.set(url, new Response('cached public shell'))), put: async (key, value) => store.set(key, value), match: async key => store.get(key)?.clone()}; }, keys: async () => [...stores.keys()], delete: async key => stores.delete(key)};
const context = vm.createContext({self, caches, URL, Set, Promise, console, importScripts: () => { self.GENIE_BUILD = 'test'; self.GENIE_ASSETS = ['index.html', 'main.dart.js']; }, fetch: async () => { if (offline) throw new Error('offline'); return new Response('fresh public shell'); }});
vm.runInContext(fs.readFileSync(new URL('../web/pwa-sw.js', import.meta.url), 'utf8'), context);
let pending;
listeners.install({waitUntil: value => pending = value}); await pending;
function request(path, {method = 'GET', authorization = false, mode = 'cors'} = {}) {
  let result;
  listeners.fetch({request: {url: new URL(path, self.location.href).href, method, mode, headers: new Headers(authorization ? {'Authorization': 'token test:test'} : {})}, respondWith: value => result = value});
  return result;
}
for (const path of ['/api/method/private_data', '/api/resource/Employee', '/private/files/selfie.jpg', '/app', '/files/receipt.jpg', 'https://external.example.test/main.dart.js']) assert.equal(request(path), undefined, `Must never cache ${path}`);
assert.equal(request('main.dart.js', {method: 'POST'}), undefined);
assert.equal(request('main.dart.js', {authorization: true}), undefined);
assert.equal(await (await request('main.dart.js')).text(), 'fresh public shell');
offline = true;
assert.equal(await (await request('main.dart.js')).text(), 'fresh public shell');
assert.equal(await (await request('/genie/', {mode: 'navigate'})).text(), 'cached public shell');
stores.set('genie-pwa-shell-old', new Map()); stores.set('another-application-cache', new Map());
listeners.activate({waitUntil: value => pending = value}); await pending;
assert.equal(stores.has('genie-pwa-shell-old'), false);
assert.equal(stores.has('another-application-cache'), true);
console.log('PWA service-worker tests passed: private/API exclusion, shell fallback, scoped cache cleanup.');
