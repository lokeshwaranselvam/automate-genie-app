const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../lib/utils/widget/webview_pull_to_refresh.dart'), 'utf8');
const script = source.match(/String webViewRefreshProbe[\s\S]*?"""([\s\S]*?)"""/)[1]
  .replace(/\$\{[^}]+\}/g, '0.5');
function probe({ top = 0, overflow = 'auto', parent, blocked = false, modal = false, ready = 'complete' } = {}) {
  const node = { scrollTop: top, scrollHeight: 1000, clientHeight: 500,
    parentElement: parent, closest: () => blocked };
  return vm.runInNewContext(script, {
    window: { innerWidth: 400, innerHeight: 700, scrollY: 0 },
    document: { readyState: ready, scrollingElement: { scrollTop: 0 },
      querySelector: () => modal, elementFromPoint: (x, y) => {
        assert.equal(x, 200); assert.equal(y, 350); return node;
      } },
    getComputedStyle: () => ({ overflowY: overflow }),
  });
}
test('allows pulling a fixed HTML form container only at its top', () => {
  assert.equal(probe(), true);
  assert.equal(probe({ top: 120 }), false);
});
test('nested scrolled lists stop refresh even when the document is at the top', () => {
  assert.equal(probe({ parent: { scrollTop: 50, scrollHeight: 1500, clientHeight: 400 } }), false);
});
test('interactive controls, maps, dialogs, busy forms and loading pages are protected', () => {
  assert.equal(probe({ blocked: true }), false);
  assert.equal(probe({ modal: true }), false);
  assert.equal(probe({ ready: 'loading' }), false);
});
