// Run with: node --test test/canteen_razorpay_bridge_test.js
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {test} = require('node:test');

const source = readFileSync(
  join(__dirname, '../lib/utils/canteen_payment_webview.dart'), 'utf8');
const script = source.match(/const canteenRazorpaySupportScript = r'''([\s\S]*?)''';/)[1];

for (const loadedInitially of [false, true]) {
  test(`preserves checkout contract with SDK ${loadedInitially ? 'already loaded' : 'loaded later'}`, () => {
    class Razorpay {
      static version = 'test';
      constructor(options) { this.options = options; }
      open() { return 'opened'; }
    }
    const window = loadedInitially ? {Razorpay} : {};
    const context = vm.createContext({window});
    vm.runInContext(script, context);
    if (!loadedInitially) window.Razorpay = Razorpay;
    const wrapped = window.Razorpay;
    vm.runInContext(script, context);
    assert.equal(window.Razorpay, wrapped, 'repeated page callback is idempotent');

    const handler = () => {};
    const modal = {ondismiss() {}};
    const options = {
      key: 'test-key', order_id: 'order123', amount: 500,
      currency: 'INR', handler, modal, theme: {color: '#16a34a'},
    };
    const checkout = new window.Razorpay(options);
    assert.equal(checkout.options.webview_intent, true);
    assert.equal(checkout.options.handler, handler);
    assert.equal(checkout.options.modal, modal);
    for (const key of Object.keys(options)) {
      assert.equal(checkout.options[key], options[key]);
    }
    assert.equal(options.webview_intent, undefined, 'original payload is unchanged');
    assert.ok(checkout instanceof Razorpay);
    assert.equal(checkout.open(), 'opened');
    assert.equal(window.Razorpay.version, 'test');
  });
}
