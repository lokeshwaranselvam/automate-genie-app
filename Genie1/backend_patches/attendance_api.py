# Replace checkin() and checkout() in ts_homegenie/ts_homegenie/utils/api.py.
# Keep both Employee Checkin face guard/attachment Server Scripts enabled.
# These are app-module functions, not a Frappe API Server Script.
import json
import requests
import frappe
from frappe.utils import getdate, nowdate, now_datetime


@frappe.whitelist(allow_guest = False)
def checkin(user, lat, lng, address=None, office_type=None, photo_url=None, face_verification=None, include_timings=None):
    if user != frappe.session.user:
        frappe.throw("You can only check in or out for yourself.", frappe.PermissionError)
    # Genie checkin timings v1
    from time import perf_counter

    timing_enabled = include_timings in (True, 1, "1", "true") or frappe.form_dict.get("include_timings") in (True, 1, "1", "true")
    checkin_started = perf_counter()

    def checkin_timed(stage, operation, *args, **kwargs):
        if not timing_enabled:
            return operation(*args, **kwargs)
        started = perf_counter()
        try:
            return operation(*args, **kwargs)
        finally:
            timings = frappe.local.response.setdefault("attendance_timings_ms", {})
            timings[stage] = round((perf_counter() - started) * 1000, 3)

    try:
        employeeid = checkin_timed("checkin_employee_lookup", frappe.db.get_value, "Employee", {"user_id": user, "status": "Active"}, "name")
        if not employeeid:
            frappe.local.response["message"] = "Employee not found or inactive"
            frappe.local.response["http_status_code"] = 404
            return

        existing_checkin = checkin_timed("checkin_existing_in", frappe.db.exists, "Employee Checkin", {
            "employee": employeeid,
            "log_type": "IN",
            "time": ["between", [f"{frappe.utils.nowdate()} 00:00:00", f"{frappe.utils.nowdate()} 23:59:59"]]
        })

        if existing_checkin:
            frappe.local.response["message"] = "Employee already checked in today!"
            frappe.local.response["http_status_code"] = 200
            return

        doc = frappe.new_doc('Employee Checkin')
        doc.employee = employeeid
        doc.log_type = 'IN'
        doc.custom_office_type = office_type
        current_time = now_datetime().strftime("%Y-%m-%d %H:%M:%S")
        doc.time = current_time
        doc.device_id = address
        doc.custom_latitude = lat
        doc.custom_longitude = lng
        doc.custom_created_using_mobile_app = 1
        checkin_timed("checkin_checkin_save", doc.save, ignore_permissions=True)

        visit = frappe.new_doc('Visit')
        visit.latitude = lat
        visit.longitude = lng
        visit.source = address
        visit.event_id = "Employee Checked In"
        visit.employee = employeeid
        visit.date = frappe.utils.nowdate()
        visit.custom_employee_checkin = doc.name
        visit.custom_created_using_mobile_app = 1
        checkin_timed("checkin_visit_save", visit.save, ignore_permissions=True)

        checkin_timed("checkin_commit", frappe.db.commit)
        frappe.local.response["message"] = 'Check-In Created Successfully'
        frappe.local.response["checkin_id"] = doc.name
    except Exception as e:
        frappe.db.rollback()
        frappe.log_error(title = f"Error on checkin-{user}",message = frappe.get_traceback())
        frappe.local.response["message"] = "Check In Denied,Check Error Log"
        frappe.local.response["http_status_code"] = 500
    finally:
        if timing_enabled:
            timings = frappe.local.response.setdefault("attendance_timings_ms", {})
            timings["checkin_total"] = round((perf_counter() - checkin_started) * 1000, 3)


@frappe.whitelist(allow_guest = False)
def checkout(user, lat=None, lng=None, address=None,lastCheckoutAddress= None,distance=None, office_type=None,location_logs=None,with_event=None,last_lat_lng=None, photo_url=None, face_verification=None, include_timings=None):
    if user != frappe.session.user:
        frappe.throw("You can only check in or out for yourself.", frappe.PermissionError)
    # Genie checkout performance v1
    from time import perf_counter

    timing_enabled = frappe.form_dict.get("include_timings") in [True, 1, "1", "true"]
    checkout_started = perf_counter()
    route_responses = {}  # Request-local only; never shared between employees.

    def checkout_timed(stage, operation, *args, **kwargs):
        if not timing_enabled:
            return operation(*args, **kwargs)
        started = perf_counter()
        try:
            return operation(*args, **kwargs)
        finally:
            timings = frappe.local.response.setdefault("attendance_timings_ms", {})
            timings[stage] = round(timings.get(stage, 0) + (perf_counter() - started) * 1000, 3)

    def checkout_maps_response(url, headers, payload):
        # Both original branches can request exactly the same driving route.
        # Reuse that response, retaining their existing Google status checks.
        if url not in route_responses:
            try:
                route_responses[url] = checkout_timed(
                    "checkout_google_distance", requests.request,
                    "GET", url, headers=headers, data=payload, timeout=(3.05, 10),
                )
            except requests.exceptions.Timeout:
                # The outer handler rolls back both attendance and receipt use.
                raise RuntimeError("Google distance lookup timed out. Please retry checkout.") from None
        return route_responses[url]

    try:
        employeeid = checkout_timed("checkout_employee_lookup", frappe.db.get_value, "Employee", {"user_id": user, "status": "Active"}, "name")
        if not employeeid:
            frappe.local.response["message"] = "Employee not found or inactive"
            frappe.local.response["http_status_code"] = 404
            return

        # Block checkout if event visit is still in progress
        event_visit_in_progress = checkout_timed("checkout_active_visit", frappe.db.exists, "Visit", {
            "employee": employeeid,
            "event_id": ["!=", ""],
            "custom_check_in_time": ["is", "set"],
            "custom_check_out_time": ["is", "not set"],
        })

        if event_visit_in_progress:
            frappe.local.response["message"] = "You cannot checkout from home while an event is still active. Please check out from the event first."
            frappe.local.response["http_status_code"] = 403
            return

        # Check if already checked out (i.e., last log was OUT today)
        
        
        # Get latest IN
        latest_checkin = checkout_timed("checkout_latest_in", frappe.get_all, "Employee Checkin", filters={
            "employee": employeeid,
            "log_type": "IN"
        }, fields=["name", "time", "custom_office_type"], order_by="time desc", limit=1)

        # Get latest OUT
        latest_checkout = checkout_timed("checkout_latest_out", frappe.get_all, "Employee Checkin", filters={
            "employee": employeeid,
            "log_type": "OUT"
        }, fields=["name", "time"], order_by="time desc", limit=1)

        if latest_checkin:
            in_time = latest_checkin[0]["time"]
            if latest_checkout and latest_checkout[0]["time"] > in_time:
                frappe.local.response["message"] = "Employee Already checked out!"
                frappe.local.response["http_status_code"] = 200
                return

        

        # Get latest office type from check-in
        custom_office_type = (latest_checkin[0].get("custom_office_type") if latest_checkin else None)

        # if office_type and custom_office_type and custom_office_type != office_type:
        #     frappe.local.response["message"] = f"Check-out Office Type mismatch! Checked in at '{custom_office_type}', trying to check out at '{office_type}'."
        #     frappe.local.response["http_status_code"] = 400
        #     return
        # Create Employee Checkin OUT entry
        doc = frappe.new_doc('Employee Checkin')
        doc.employee = employeeid
        doc.log_type = 'OUT'
        doc.custom_office_type = custom_office_type or office_type
        current_time = now_datetime().strftime("%Y-%m-%d %H:%M:%S")
        doc.time = current_time
        doc.device_id = address
        doc.custom_latitude = lat
        doc.custom_longitude = lng
        doc.custom_created_using_mobile_app = 1
        checkout_timed("checkout_checkin_save", doc.save, ignore_permissions=True)

        # Create Visit log for checkout
        visit = frappe.new_doc('Visit')
        
        visit.destination_lat = lat
        visit.destination_lng = lng
        visit.custom_created_using_mobile_app = 1

        previous_visit = checkout_timed("checkout_previous_visit", frappe.db.sql, """
            SELECT event_id, creation, latitude, longitude, destination_lat, destination_lng, source, destination
            FROM `tabVisit`
            WHERE employee = %(emp)s
            ORDER BY creation DESC
            LIMIT 1
        """, {"user": user,"emp": employeeid}, as_dict=True)
        
        if len(previous_visit) == 0:
            frappe.throw('No Visit Records Found For this User')
            
        prev = previous_visit[0]

        if prev['event_id'] != "Employee Checked In" and prev['event_id'] !="Employee Checked Out":

            # if last_lat_lng:
                
            #     lat_str, lng_str = last_lat_lng.split(',') if ',' in last_lat_lng else (None, None)

            # else:
                
            if prev:
                if prev.event_id == "Employee Checked In":
                    lat_str = prev.get("latitude")
                    lng_str = prev.get("longitude")
                else:
                    lat_str = prev.get("destination_lat")
                    lng_str = prev.get("destination_lng")

            visit.source = prev['destination']
            
            if not lat_str and not lng_str:
                frappe.throw('In Previous Visit latitude and longitude Missing')
                
            if not lat and not lng:
                frappe.throw('Current latitude and longitude missing. Please remove the app from recent tabs and reopen it.')

            origin = f"{lat_str},{lng_str}"
            destination = f"{lat},{lng}"
            
            api_key = frappe.conf.get("google_maps_api_key") or frappe.throw("Google Maps is not configured on the server. Contact your administrator.")
            visit.custom_from_google_api = 1
            url = (
                    f"https://maps.googleapis.com/maps/api/distancematrix/json"
                    f"?origins={origin}&destinations={destination}&key={api_key}&mode=driving"
                )
            payload = {}
            headers = {}

            if getdate(prev['creation']) == getdate(nowdate()):
                response = checkout_maps_response(url, headers, payload)
                data = json.loads(response.text)
                if data['status'] == 'OK':
                    if data['rows'][0]['elements'][0]['status'] == 'OK':
                        visit.custom_distance = data['rows'][0]['elements'][0]['distance']['text']
                    else:
                        frappe.log_error(title='Google Api Error',message = data)
                        frappe.throw('Google Api Error - Check Error Log')
                else:
                    frappe.log_error(title='Google Api Error',message = data)
                    frappe.throw('Google Api Error - Check Error Log')

            visit.latitude = prev['destination_lat']

            visit.longitude = prev['destination_lng']
        
        elif prev['event_id'] == "Employee Checked In":

            visit.latitude = prev['latitude']

            visit.longitude = prev['longitude']

            visit.source = prev['source']
            
        elif prev['event_id'] == "Employee Checked Out":
            
            frappe.throw("Your previous visit type is invalid (must be Employee Check-In Visit or Event Visit), so you are not allowed to check out.")
            


     
        # logs_str = ""
        # if location_logs:
        #     try:
        #         if isinstance(location_logs, str):
        #             location_logs = json.loads(location_logs)
        #         logs_str = json.dumps(location_logs)
        #     except Exception as e:
        #         logs_str = "[]"
        #         frappe.log_error(title = f"Error parsing location logs",message = frappe.get_traceback())

        # Combine address + newline + logs into destination
        # visit.destination = f"{address}\n{logs_str}"
        visit.destination = address
        visit.event_id = "Employee Checked Out"
        visit.employee = employeeid
        # visit.custom_distance = distance
        visit.date = frappe.utils.nowdate()
        visit.custom_employee_checkin = doc.name
        if with_event == "true" and getdate(prev['creation']) == getdate(nowdate()):

            # lat_str, lng_str = last_lat_lng.split(',') if last_lat_lng and ',' in last_lat_lng else (None, None)

            origin = f"{visit.latitude},{visit.longitude}"
            destination = f"{lat},{lng}"
            
            api_key = frappe.conf.get("google_maps_api_key") or frappe.throw("Google Maps is not configured on the server. Contact your administrator.")
            visit.custom_from_google_api = 1
            url = (
                    f"https://maps.googleapis.com/maps/api/distancematrix/json"
                    f"?origins={origin}&destinations={destination}&key={api_key}&mode=driving"
                )
            payload = {}
            headers = {}

            response = checkout_maps_response(url, headers, payload)

            data = json.loads(response.text)
            
            if data['status'] == 'OK':
                if data['rows'][0]['elements'][0]['status'] == 'OK':
                    visit.custom_distance = data['rows'][0]['elements'][0]['distance']['text']
                else:
                    frappe.log_error(title='Google Api Error',message = data)
                    frappe.throw('Google Api Error - Check Error Log')
            else:
                frappe.log_error(title='Google Api Error',message = data)
                frappe.throw('Google Api Error - Check Error Log')


        checkout_timed("checkout_visit_save", visit.save, ignore_permissions=True)

        checkout_timed("checkout_commit", frappe.db.commit)
        frappe.local.response["message"] = 'Check-Out Created Successfully'
        frappe.local.response["http_status_code"] = 200

    except Exception as e:
        frappe.db.rollback()
        frappe.log_error(title = f"Error on checkout-{user}",message = frappe.get_traceback())
        frappe.local.response["message"] = str(e)
        frappe.local.response["http_status_code"] = 500
    finally:
        if timing_enabled:
            timings = frappe.local.response.setdefault("attendance_timings_ms", {})
            timings["checkout_total"] = round((perf_counter() - checkout_started) * 1000, 3)
