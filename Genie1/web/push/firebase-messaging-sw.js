/* Configuration contains only Firebase's public WEB app registration. */
importScripts('../pwa-config.js');
if (self.GENIE_WEB_CONFIG?.firebase) {
  importScripts('https://www.gstatic.com/firebasejs/12.1.0/firebase-app-compat.js');
  importScripts('https://www.gstatic.com/firebasejs/12.1.0/firebase-messaging-compat.js');
  firebase.initializeApp(self.GENIE_WEB_CONFIG.firebase);
  firebase.messaging().onBackgroundMessage(payload => {
    // Firebase displays notification payloads itself. Avoid duplicate alerts.
    if (payload.notification) return;
    const data = payload.data || {};
    return self.registration.showNotification(data.title || 'New pending work', {
      body: data.body || 'Open automategenie.ai to view your updates.',
      icon: new URL('../icons/Icon-192.png', self.location.href).href,
      tag: payload.messageId || undefined,
      data: {appUrl: new URL('../', self.location.href).href}
    });
  });
}
self.addEventListener('notificationclick', event => {
  event.notification.close();
  // Notifications return to the authenticated app, never to arbitrary push URLs.
  const app = new URL('../', self.location.href).href;
  event.waitUntil(self.clients.matchAll({type: 'window', includeUncontrolled: true}).then(async clients => {
    const existing = clients.find(client => client.url.startsWith(app));
    if (existing) return existing.focus();
    return self.clients.openWindow(app);
  }));
});
