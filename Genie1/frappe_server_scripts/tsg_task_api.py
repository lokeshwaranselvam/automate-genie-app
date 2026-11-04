action = frappe.form_dict.get("action") or "get"


# Logged-in User changed below on 25/06/2026
# user = frappe.session.user

# # Logged-in User Roles
# roles = frappe.get_roles(user)

# Logged-in User changed above on 25/06/2026

def is_true(value):
    return str(value or "").lower() in ("1", "true", "yes", "y", "on")


def resolve_enabled_user(value):
    candidate = str(value or "").strip()
    if not candidate:
        return None

    user_name = frappe.db.get_value("User", candidate, "name")
    if not user_name:
        user_name = frappe.db.get_value("User", {"email": candidate}, "name")

    if not user_name:
        return None

    enabled = frappe.db.get_value("User", user_name, "enabled")
    if not enabled:
        return None

    return user_name


def strip_quill_html(text):
    if not text:
        return None

    s = text or ""
    s = s.replace('<div class="ql-editor read-mode">', "")
    s = s.replace('<div class="ql-editor">', "")
    s = s.replace("<div>", "")
    s = s.replace("</div>", "")
    s = s.replace("<p>", "")
    s = s.replace("</p>", "")
    s = s.replace("<br>", "")
    s = s.replace("<br/>", "")
    s = s.replace("<br />", "")
    s = s.replace("&nbsp;", " ")
    s = s.replace("&amp;", "&")
    s = s.replace("&lt;", "<")
    s = s.replace("&gt;", ">")
    s = " ".join(s.split())

    if not s:
        return None

    return s


# ----------------------------------------------------
# GET USERS FOR DROPDOWN
# ----------------------------------------------------
if action == "get_users":
    users = frappe.db.get_list(
        "User",
        filters={"enabled": 1},
        fields=["name", "full_name"],
        order_by="full_name asc",
        limit_page_length=500,
    )

    user_list = []

    for d in users:
        if d.get("name") not in ["Administrator", "Guest"]:
            user_list.append({
                "email": d.get("name"),
                "full_name": d.get("full_name"),
                "department": "",
                "designation": "",
            })

    frappe.response["message"] = {
        "status": "success",
        "action": "get_users",
        "users": user_list,
    }


# ----------------------------------------------------
# GET PROJECTS
# ----------------------------------------------------
elif action == "get_projects":
    projects = frappe.db.get_list(
        "Project",
        filters={"status": ["!=", "Cancelled"]},
        fields=["name", "project_name", "status", "priority"],
        order_by="modified desc",
        limit_page_length=500,
    )

    project_list = []

    for d in projects:
        project_list.append({
            "project": d.get("name"),
            "project_name": d.get("project_name"),
            "status": d.get("status"),
            "priority": d.get("priority"),
        })

    frappe.response["message"] = {
        "status": "success",
        "action": "get_projects",
        "projects": project_list,
    }


# ----------------------------------------------------
# GET TASK TYPES
# ----------------------------------------------------
elif action == "get_task_types":
    task_types = frappe.db.sql(
        """
        SELECT DISTINCT type
        FROM `tabTask`
        WHERE IFNULL(type, '') != ''
        ORDER BY type ASC
        """,
        as_dict=True,
    )

    type_list = []

    for d in task_types:
        if d.get("type"):
            type_list.append({"type": d.get("type")})

    frappe.response["message"] = {
        "status": "success",
        "action": "get_task_types",
        "task_types": type_list,
    }


# ----------------------------------------------------
# COMPLETE TASK
# ----------------------------------------------------
elif action == "complete":
    task_id = (frappe.form_dict.get("task_id") or "").strip()
    current_user = frappe.session.user

    if not task_id:
        frappe.throw("task_id is required.")
    if not current_user or current_user == "Guest":
        frappe.throw("Sign in to complete an assigned task.")

    task = frappe.get_doc("Task", task_id)
    assigned_todo = frappe.db.exists(
        "ToDo",
        {
            "reference_type": "Task",
            "reference_name": task.name,
            "allocated_to": current_user,
            "status": ["!=", "Cancelled"],
        },
    )
    assigned_task = frappe.db.sql(
        """
        SELECT name
        FROM `tabTask`
        WHERE name = %(task_id)s
          AND FIND_IN_SET(
                %(current_user)s,
                REPLACE(
                    REPLACE(
                        REPLACE(IFNULL(_assign, ''), '[', ''),
                        ']', ''
                    ),
                    '"', ''
                )
          )
        LIMIT 1
        """,
        {"task_id": task.name, "current_user": current_user},
        as_dict=True,
    )

    if not assigned_todo and not assigned_task:
        frappe.throw("You can complete only tasks assigned to your user.")

    task.status = "Completed"
    task.save(ignore_permissions=True)

    todo_rows = frappe.db.sql(
        """
        SELECT name
        FROM `tabToDo`
        WHERE reference_type = 'Task'
          AND reference_name = %(task_id)s
          AND allocated_to = %(current_user)s
        ORDER BY modified DESC
        LIMIT 1
        """,
        {"task_id": task.name, "current_user": current_user},
        as_dict=True,
    )
    if todo_rows:
        todo_doc = frappe.get_doc("ToDo", todo_rows[0]["name"])
        todo_doc.status = "Closed"
        todo_doc.save(ignore_permissions=True)

    frappe.response["message"] = {
        "status": "success",
        "action": "complete",
        "task_id": task.name,
        "task_status": task.status,
        "todo_status": "Closed" if todo_rows else None,
    }


# ----------------------------------------------------
# SAVE TASK
# ----------------------------------------------------
elif action == "save":
    task_id = frappe.form_dict.get("task_id")

    subject = (frappe.form_dict.get("subject") or "").strip()
    project = frappe.form_dict.get("project")
    custom_project_name = frappe.form_dict.get("custom_project_name")

    task_status = frappe.form_dict.get("task_status")
    task_priority = frappe.form_dict.get("task_priority")
    task_type = frappe.form_dict.get("type")
    parent_task = frappe.form_dict.get("parent_task")

    task_description = frappe.form_dict.get("task_description")
    assigned_email = (frappe.form_dict.get("assigned_email") or "").strip()
    assigned_user = resolve_enabled_user(assigned_email)

    todo_status = frappe.form_dict.get("todo_status")
    todo_priority = frappe.form_dict.get("todo_priority")
    todo_date = frappe.form_dict.get("todo_date")
    todo_description = frappe.form_dict.get("todo_description")

    if not subject:
        frappe.throw("Subject is required.")

    if assigned_email and not assigned_user:
        frappe.throw(
            "The selected assignee is not an enabled Frappe User. "
            "Choose a user from the suggestions and try again."
        )

    if not assigned_user:
        assigned_user = resolve_enabled_user(frappe.session.user)
    if not assigned_user:
        frappe.throw("Choose an enabled Frappe User before creating the task.")

    if task_id:
        task = frappe.get_doc("Task", task_id)
        current_user = frappe.session.user
        is_task_member = task.owner == current_user or frappe.db.exists(
            "ToDo",
            {
                "reference_type": "Task",
                "reference_name": task.name,
                "allocated_to": current_user,
                "status": ["!=", "Cancelled"],
            },
        )
        if not is_task_member and not frappe.has_permission("Task", "write", task.name):
            frappe.throw("You can edit only tasks you created or are assigned to.")
    else:
        task = frappe.new_doc("Task")

    task.subject = subject
    task.project = project
    task.custom_project_name = custom_project_name
    task.status = task_status or "Open"
    task.priority = task_priority or "Medium"
    task.type = task_type
    task.parent_task = parent_task
    task.description = task_description

    if task_id:
        task.save(ignore_permissions=True)
    else:
        task.insert(ignore_permissions=True)

    if assigned_user:
        frappe.db.set_value("Task", task.name, "_assign", '["' + assigned_user + '"]')
    else:
        frappe.db.set_value("Task", task.name, "_assign", None)

    todo_name = frappe.db.get_value(
        "ToDo",
        {
            "reference_type": "Task",
            "reference_name": task.name,
        },
        "name",
    )

    if todo_name:
        todo_doc = frappe.get_doc("ToDo", todo_name)
    else:
        todo_doc = frappe.new_doc("ToDo")
        todo_doc.reference_type = "Task"
        todo_doc.reference_name = task.name

    todo_doc.allocated_to = assigned_user
    todo_doc.status = todo_status or "Open"
    todo_doc.priority = todo_priority or "Medium"
    todo_doc.date = todo_date
    todo_doc.description = todo_description

    if todo_name:
        todo_doc.save(ignore_permissions=True)
    else:
        todo_doc.insert(ignore_permissions=True)

    frappe.response["message"] = {
        "status": "success",
        "action": "save",
        "task_id": task.name,
        "subject": task.subject,
        "project": task.project,
        "custom_project_name": task.custom_project_name,
        "assigned_to": assigned_user,
        "todo_id": todo_doc.name,
    }


# ----------------------------------------------------
# GET TASK LIST
# Supports:
#   /api/method/Tsg?action=get&all_data=1
#   /api/method/Tsg?action=get&from_date=2026-01-01&to_date=2026-06-01
#   /api/method/Tsg?action=get&project=PROJECT-ID
#   /api/method/Tsg?action=get&channel=HR
# ----------------------------------------------------
else:
    from_date = frappe.form_dict.get("from_date")
    to_date = frappe.form_dict.get("to_date")
    all_data = is_true(frappe.form_dict.get("all_data"))

    channel = frappe.form_dict.get("channel")
    project = frappe.form_dict.get("project")
    assigned_to_only = is_true(frappe.form_dict.get("assigned_to_only"))

    conditions = ""
    values = {}

    if assigned_to_only:
        assigned_user = frappe.session.user
        if not assigned_user or assigned_user == "Guest":
            frappe.throw("Sign in to view tasks assigned to you.")
        values["assigned_user"] = assigned_user
        conditions += """
            AND (
                EXISTS (
                    SELECT 1
                    FROM `tabToDo` assigned_todo
                    WHERE assigned_todo.reference_type = 'Task'
                      AND assigned_todo.reference_name = t.name
                      AND assigned_todo.allocated_to = %(assigned_user)s
                )
                OR t._assign LIKE CONCAT('%%\"', %(assigned_user)s, '\"%%')
            )
        """
    
    # changed below line on 25/06/2026
    # values["user"] = user

    # allowed_roles = ["System Manager", "Trainee", "Operations"]
    
    # if not any(role in roles for role in allowed_roles):
    
    #     project_list = frappe.db.sql("""
    #         SELECT DISTINCT project
    #         FROM `tabTask`
    #         WHERE project IN (
    #             SELECT DISTINCT t.project
    #             FROM `tabTask` t
    #             LEFT JOIN `tabToDo` td
    #                 ON td.reference_name = t.name
    #                 AND td.reference_type='Task'
    #             WHERE
    #                 t.owner = %(user)s
    #                 OR td.allocated_to = %(user)s
    #                 OR t._assign LIKE CONCAT('%%', %(user)s, '%%')
    #         )
    #     """, {"user": user}, as_dict=True)
    
    #     projects = [d.project for d in project_list if d.project]
    
    #     if projects:
    #         conditions += " AND t.project IN %(projects)s"
    #         values["projects"] = tuple(projects)
    #     else:
    #         conditions += " AND 1 = 0"
    # changed Above lines on 25/06/2026

    if project:
        conditions += """
            AND t.project = %(project)s
        """
        values["project"] = project

    elif channel:
        conditions += """
            AND UPPER(TRIM(t.custom_project_name)) = UPPER(TRIM(%(channel)s))
        """
        values["channel"] = channel

    elif not all_data:
        if not from_date:
            from_date = frappe.utils.get_first_day(
                frappe.utils.today(),
                as_str=True,
            )

        if not to_date:
            to_date = frappe.utils.today()

        conditions += """
            AND t.creation >= %(from_date)s
            AND t.creation < %(to_date_end)s
        """

        values["from_date"] = from_date
        values["to_date_end"] = frappe.utils.add_days(to_date, 1)

    limit_sql = ""
    if not all_data:
        limit_sql = "LIMIT 1000"

    task_data = frappe.db.sql(
        f"""
        SELECT
            t.name AS task_id,
            t.name AS name,
            t.subject,

            t.project,
            t.custom_project_name,

            t.status AS task_status,
            t.priority AS task_priority,

            t.type,
            t.parent_task,

            t.description AS task_description,

            t.creation,
            t.modified,

            t.completed_by,
            t.completed_on,

            t.owner AS task_owner_email,
            u_owner.full_name AS task_owner_name,

            REPLACE(
                REPLACE(
                    REPLACE(
                        REPLACE(
                            IFNULL(t._assign, ''),
                        '[', ''),
                    ']', ''),
                '"', ''),
            '\\\\', '') AS assigned_email,

            u_assign.full_name AS assigned_user_name,

            td.allocated_to,
            u_todo.full_name AS todo_assigned_user_name,

            td.status AS todo_status,
            td.priority AS todo_priority,
            td.date AS todo_date,
            td.description AS todo_description

        FROM `tabTask` t

        LEFT JOIN `tabUser` u_owner
            ON u_owner.name = t.owner

        LEFT JOIN `tabUser` u_assign
            ON u_assign.name = REPLACE(
                REPLACE(
                    REPLACE(
                        REPLACE(
                            IFNULL(t._assign, ''),
                        '[', ''),
                    ']', ''),
                '"', ''),
            '\\\\', '')

        LEFT JOIN (
            SELECT
                x.reference_name,
                x.allocated_to,
                x.status,
                x.priority,
                x.date,
                x.description
            FROM `tabToDo` x
            INNER JOIN (
                SELECT
                    reference_name,
                    MAX(modified) AS max_modified
                FROM `tabToDo`
                WHERE reference_type = 'Task'
                GROUP BY reference_name
            ) y
                ON y.reference_name = x.reference_name
                AND y.max_modified = x.modified
            WHERE x.reference_type = 'Task'
        ) td
            ON td.reference_name = t.name

        LEFT JOIN `tabUser` u_todo
            ON u_todo.name = td.allocated_to

        WHERE
            t.docstatus != 2
            {conditions}

        ORDER BY
            t.creation DESC,
            t.subject ASC

        {limit_sql}
        """,
        values,
        as_dict=True,
    )

    for row in task_data:
        row["task_description"] = strip_quill_html(row.get("task_description"))
        row["todo_description"] = strip_quill_html(row.get("todo_description"))

        if not row.get("assigned_email"):
            row["assigned_email"] = None

    frappe.response["message"] = {
        "status": "success",
        "action": "get",
        "all_data": all_data,
        "project": project,
        "channel": channel,
        "from_date": from_date,
        "to_date": to_date,
        "assigned_to_only": assigned_to_only,
        "assigned_user": frappe.session.user if assigned_to_only else None,
        "csrf_token": frappe.session.get("csrf_token") or frappe.session.data.csrf_token,
        "total_tasks": len(task_data),
        "task_data": task_data,
    }
