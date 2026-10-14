# Supplied checkout baseline with the Maps key replaced by a test value.
@frappe.whitelist(allow_guest = False)
def checkout(user, lat=None, lng=None, address=None,lastCheckoutAddress= None,distance=None, office_type=None,location_logs=None,with_event=None,last_lat_lng=None):
    try:
        employeeid = frappe.db.get_value("Employee", {"user_id": user, "status": "Active"}, "name")
        if not employeeid:
            frappe.local.response["message"] = "Employee not found or inactive"
            frappe.local.response["http_status_code"] = 404
            return

        # Block checkout if event visit is still in progress
        event_visit_in_progress = frappe.db.exists("Visit", {
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
        latest_checkin = frappe.get_all("Employee Checkin", filters={
            "employee": employeeid,
            "log_type": "IN"
        }, fields=["name", "time"], order_by="time desc", limit=1)

        # Get latest OUT
        latest_checkout = frappe.get_all("Employee Checkin", filters={
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
        custom_office_type = frappe.db.get_value(
            "Employee Checkin",
            {
                "employee": employeeid,
                "log_type": "IN"
            },
            "custom_office_type",
            order_by="time desc"
        )

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
        doc.save(ignore_permissions=True)

        # Create Visit log for checkout
        visit = frappe.new_doc('Visit')
        
        visit.destination_lat = lat
        visit.destination_lng = lng
        visit.custom_created_using_mobile_app = 1

        previous_visit = frappe.db.sql("""
            SELECT *
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
            
            api_key = "test-maps-key"
            visit.custom_from_google_api = 1
            url = (
                    f"https://maps.googleapis.com/maps/api/distancematrix/json"
                    f"?origins={origin}&destinations={destination}&key={api_key}&mode=driving"
                )
            payload = {}
            headers = {}

            if getdate(prev['creation']) == getdate(nowdate()):
                response = requests.request("GET", url, headers=headers, data=payload)
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
            
            api_key = "test-maps-key"
            visit.custom_from_google_api = 1
            url = (
                    f"https://maps.googleapis.com/maps/api/distancematrix/json"
                    f"?origins={origin}&destinations={destination}&key={api_key}&mode=driving"
                )
            payload = {}
            headers = {}

            response = requests.request("GET", url, headers=headers, data=payload)

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


        visit.save(ignore_permissions=True)

        frappe.db.commit()
        frappe.local.response["message"] = 'Check-Out Created Successfully'
        frappe.local.response["http_status_code"] = 200

    except Exception as e:
        frappe.db.rollback()
        frappe.log_error(title = f"Error on checkout-{user}",message = frappe.get_traceback())
        frappe.local.response["message"] = str(e)
        frappe.local.response["http_status_code"] = 500
