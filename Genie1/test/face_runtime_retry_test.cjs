const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function bridge(failFirst) {
  const workers = [];
  class Worker {
    constructor() { this.failed = failFirst && workers.length === 0; workers.push(this); }
    terminate() { this.terminated = true; }
    postMessage(message) {
      queueMicrotask(() => this.onmessage({data: this.failed
        ? {id: message.id, error: 'Failed to fetch dynamically imported module'}
        : {id: message.id, value: true}}));
    }
  }
  const self = {};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,
    '../web/face/face_bridge.js'), 'utf8'), {
    self, Worker, URL, setTimeout, clearTimeout,
    document: {currentScript: {src: 'https://erp.example.test/genie/face/face_bridge.js'}},
  });
  return {api: self.genieFace, workers};
}

test('Failed runtime loading is discarded and Retry uses a new worker', async () => {
  const {api, workers} = bridge(true);
  await assert.rejects(api.warmup(), /Failed to fetch/);
  assert.equal(workers[0].terminated, true);
  assert.equal(await api.warmup(), true);
  assert.equal(workers.length, 2);
  api.release();
});

test('Successful runtime warmup continues to reuse the existing worker', async () => {
  const {api, workers} = bridge(false);
  await api.warmup();
  await api.warmup();
  assert.equal(workers.length, 1);
  assert.notEqual(workers[0].terminated, true);
  api.release();
});

test('Concurrent failed warmups settle and allow the next attempt', async () => {
  const {api, workers} = bridge(true);
  const results = await Promise.allSettled([api.warmup(), api.warmup()]);
  assert.ok(results.every(r => r.status === 'rejected'));
  assert.equal(await api.warmup(), true);
  assert.equal(workers.length, 2);
  api.release();
});
