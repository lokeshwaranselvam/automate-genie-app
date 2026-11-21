// Event Client Script. Replace the old OTP-blocking script with this file.
// custom_validate stores only a verified customer OTP; no checkbox field is used.
frappe.ui.form.on('Event', {
    async refresh(frm) {
        frm.set_df_property('custom_validate', 'hidden', 1);
        frm.set_df_property('custom_otp', 'read_only', 1);
        if (frm.doc.status !== 'Completed' || !has_valid_reference(frm)) return;
        let report;
        try {
            const result = await frappe.call({method: 'event_visit_report', type: 'POST', args: {action: 'get', event_id: frm.doc.name}});
            report = result.message;
        } catch (_) { return; }
        if (report?.verification_required && !report.is_verified) {
            frm.add_custom_button(__('Verify Customer OTP'), () => {
                frappe.prompt([{fieldname: 'otp', fieldtype: 'Data', label: __('Customer OTP'), reqd: 1}], async (values) => {
                    const entered = String(values.otp || '').trim();
                    if (!/^\d{6}$/.test(entered)) {
                        frappe.msgprint(__('Enter the 6-digit customer OTP.'));
                        return;
                    }
                    // API enforces selection policy, assignment, attempts, and comparison.
                    const result = await frappe.call({method: 'event_visit_report', type: 'POST',
                        args: {action: 'verify', event_id: frm.doc.name, custom_validate: entered}, freeze: true});
                    await frm.reload_doc();
                    frappe.msgprint(__(result.message?.detail || (result.message?.is_verified ? 'OTP verified.' : 'Invalid OTP.')));
                }, __('Verify Customer OTP'), __('Verify'));
            });
        }
    },
    async before_save(frm) {
        if (!has_valid_reference(frm)) return;
        if (frm.doc.status === 'Completed' &&
            (!(frm.doc.custom_in || frm.doc.custom_check_in) || !(frm.doc.custom_out || frm.doc.custom_check_out))) {
            frappe.throw(__('Check-in and Check-out times must be set before completing the Event.'));
        }
        // Protected fields are written only by event_visit_report. Do not
        // write custom_validate or read the expected OTP in the browser.
        // Missing/incorrect OTP does not block completion.
    },
    async after_save(frm) {
        if (!has_valid_reference(frm)) return;
        try {
            const result = await frappe.call({method: 'event_visit_report', type: 'POST',
                args: {action: 'ensure_otp', event_id: frm.doc.name}});
            if (result.message?.otp_generation?.otp_ready) await frm.reload_doc();
        } catch (err) {
            frappe.msgprint({title: __('OTP Setup Error'), message: __('Event saved, but its customer OTP could not be prepared. Contact your administrator.'), indicator: 'red'});
        }
    }
});

function has_valid_reference(frm) {
    return (frm.doc.event_participants || []).some(row => ['Lead', 'Opportunity', 'Customer'].includes(row.reference_doctype));
}
