# Document Event Server Script: Event / After Save.
# Queue after commit; no WHAPI/network call runs inside Event checkout.
previous = doc.get_doc_before_save()
checkout = doc.get("custom_check_out") or doc.get("custom_out")
previous_checkout = (previous.get("custom_check_out") or previous.get("custom_out")) if previous else None
just_completed = bool(previous and checkout and doc.get("status") == "Completed"
    and (not previous_checkout or previous.get("status") != "Completed"))
if just_completed:
    try:
        policy = frappe.call("event_visit_report", action="verification_policy")["verification_policy"]
        category = doc.get("event_category") or doc.get("custom_event_category") or ""
        already_sent = frappe.db.exists("Comment", {"reference_doctype": "Event",
            "reference_name": doc.name, "subject": "EVENT_CHECKOUT_OTP_ACCEPTED|" + doc.name})
        if policy["visible"] and category in policy["categories"] and not already_sent:
            ticket = frappe.get_doc({"doctype": "Comment", "comment_type": "Info",
                "reference_doctype": "Event", "reference_name": doc.name,
                "subject": "Genie OTP queued delivery", "content": "Queued"})
            ticket.insert(ignore_permissions=True)
            frappe.enqueue("event_visit_report", action="send_checkout_otp", queue="short", timeout=90,
                is_async=True, enqueue_after_commit=True, event_id=doc.name, ticket_id=ticket.name)
    except Exception:
        frappe.log_error(title="Event checkout OTP queue failed",
            message="Event: " + doc.name + ". Checkout is preserved. Check Redis queue, worker configuration and Server Script availability. No synchronous send or automatic retry was attempted.")
