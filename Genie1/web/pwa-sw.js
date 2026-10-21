/* Cache only the public application shell. ERP, uploads, and private data
 * are always network-only, including authenticated GET requests. */
importScripts('pwa-assets.js');
const PREFIX = 'genie-pwa-shell-';
const CACHE = PREFIX + self.GENIE_BUILD;
const BASE = new URL('./', self.location.href);
const PUBLIC = new Set(self.GENIE_ASSETS.map(path => new URL(path, BASE).href));
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll([...PUBLIC])));
  // Activate updates when existing tabs close. Never reload an in-progress form.
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith(PREFIX) && key !== CACHE).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== BASE.origin) return;
  // Never store an Authorization request, even if its URL names a public file.
  if (request.headers.has('Authorization')) return;
  const isEntry = request.mode === 'navigate' && (url.pathname === BASE.pathname || url.pathname === BASE.pathname + 'index.html');
  if (!isEntry && !PUBLIC.has(url.href)) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cacheKey = isEntry ? new URL('index.html', BASE).href : url.href;
    try {
      const response = await fetch(request);
      if (response.ok && response.type !== 'opaque') await cache.put(cacheKey, response.clone());
      return response;
    } catch (error) {
      const saved = await cache.match(cacheKey);
      if (saved) return saved;
      throw error;
    }
  })());
});
