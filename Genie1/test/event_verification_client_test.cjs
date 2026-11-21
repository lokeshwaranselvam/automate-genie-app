const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function setup(doc, visible = true) {
    let handlers;
    const buttons = [];
    const frappe = {
        ui: {form: {on: (_, value) => { handlers = value; }}},
        throw: (message) => {throw new Error(message);},
        call: async () => ({message: {verification_required: visible && doc.event_category === 'Site Visit', is_verified: Boolean(doc.custom_validate)}}),
    };
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../frappe_server_scripts/event_verification_client.js'), 'utf8'), {frappe, __: (value) => value});
    const frm = {doc, set_df_property() {}, add_custom_button(label) {buttons.push(label);},
        async set_value(field, value) {this.doc[field] = value;}};
    return {handlers, frm, buttons, frappe};
}
const event = (extra = {}) => ({status: 'Completed', custom_in: '09:00', custom_out: '10:00',
    custom_otp: '123456', custom_validate: '', event_category: 'Site Visit',
    event_participants: [{reference_doctype: 'Opportunity'}], ...extra});

test('completion saves without OTP or verification input', async () => {
    const {handlers, frm} = setup(event({custom_otp: ''}));
    await handlers.before_save(frm);
    assert.equal(frm.doc.custom_validate, '');
});
test('ordinary saves do not write or recompute protected verification fields', async () => {
    for (const entered of ['654321', '', '123456']) {
        const {handlers, frm} = setup(event({custom_validate: entered}));
        await handlers.before_save(frm);
        assert.equal(frm.doc.custom_validate, entered);
        assert.equal(frm.doc.status, 'Completed');
    }
});
test('check-in/out requirement remains enforced', async () => {
    const {handlers, frm} = setup(event({custom_out: ''}));
    await assert.rejects(handlers.before_save(frm), /Check-in and Check-out/);
});
test('app timestamp fields are also supported', async () => {
    const {handlers, frm} = setup(event({custom_in: '', custom_out: '', custom_check_in: '09:00', custom_check_out: '10:00'}));
    await handlers.before_save(frm);
    assert.equal(frm.doc.custom_validate, '');
});
test('verification button follows API eligibility and completed status', async () => {
    for (const [visible, category, status, count] of [[true, 'Site Visit', 'Completed', 1], [false, 'Site Visit', 'Completed', 0], [true, 'Installation', 'Completed', 0], [true, 'Site Visit', 'Open', 0]]) {
        const {handlers, frm, buttons} = setup(event({event_category: category, status}), visible);
        await handlers.refresh(frm);
        assert.equal(buttons.length, count);
    }
});

test('already verified API state hides the button without reading validation OTP', async () => {
    const {handlers, frm, buttons, frappe} = setup(event({custom_validate: undefined}));
    frappe.call = async () => ({message: {verification_required: true, is_verified: true}});
    await handlers.refresh(frm);
    assert.equal(buttons.length, 0);
});

test('after_save requests API generation without reading or writing the OTP', async () => {
    const {handlers, frm, frappe} = setup(event({name: 'E1', custom_otp: undefined}));
    let calls = 0;
    let reloads = 0;
    frm.reload_doc = async () => {reloads++;};
    frappe.call = async ({args}) => {
        calls++;
        assert.deepEqual(Object.keys(args).sort(), ['action', 'event_id']);
        assert.equal(args.action, 'ensure_otp');
        assert.equal(args.event_id, 'E1');
        return {message: {otp_generation: {otp_ready: true}}};
    };
    await handlers.after_save(frm);
    assert.equal(calls, 1);
    assert.equal(reloads, 1);
    assert.equal(frm.doc.custom_otp, undefined);
});
