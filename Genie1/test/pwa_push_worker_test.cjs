const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function worker() {
  let receive;
  const notifications = [];
  const handlers = {};
  const opened = [];
  const self = {
    GENIE_WEB_CONFIG: {firebase: {projectId: 'test-project'}},
    location: {href: 'https://erp.example.test/genie/push/firebase-messaging-sw.js'},
    registration: {showNotification: async (...args) => notifications.push(args)},
    addEventListener: (name, callback) => handlers[name] = callback,
    clients: {matchAll: async () => [], openWindow: async url => opened.push(url)},
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,
    '../web/push/firebase-messaging-sw.js'), 'utf8'), {
    self, URL, importScripts() {},
    firebase: {initializeApp() {}, messaging: () => ({
      onBackgroundMessage: callback => receive = callback,
    })},
  });
  return {receive, notifications, handlers, opened};
}

test('Data-only background push displays its title and body', async () => {
  const w = worker();
  await w.receive({messageId: 'one', data: {title: 'Assigned work', body: 'Open Genie'}});
  assert.equal(w.notifications.length, 1);
  assert.equal(w.notifications[0][0], 'Assigned work');
  assert.equal(w.notifications[0][1].body, 'Open Genie');
});

test('Firebase notification payload does not create a duplicate alert', async () => {
  const w = worker();
  await w.receive({notification: {title: 'Firebase alert'}});
  assert.equal(w.notifications.length, 0);
});

test('Notification click opens the PWA rather than a supplied external URL', async () => {
  const w = worker();
  let waiting;
  w.handlers.notificationclick({
    notification: {close() {}, data: {appUrl: 'https://other.example.test/'}},
    waitUntil: promise => waiting = promise,
  });
  await waiting;
  assert.deepEqual(w.opened, ['https://erp.example.test/genie/']);
});
