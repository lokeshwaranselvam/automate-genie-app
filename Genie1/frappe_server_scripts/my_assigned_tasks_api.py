# Frappe Server Script settings:
#   Script Type: API
#   API Method: my_assigned_tasks
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled
#
# GET  /api/method/my_assigned_tasks?action=get
# POST /api/method/my_assigned_tasks?action=complete&task_id=TASK-ID

action = (frappe.form_dict.get("action") or "get").strip().lower()
current_user = frappe.session.user

if not current_user or current_user == "Guest":
    frappe.throw("Sign in to access your assigned tasks.")


def get_assigned_task(task_id, user):
    """Return a Task only when it is assigned to this logged-in user."""
    rows = frappe.db.sql(
        """
        SELECT t.name
        FROM `tabTask` t
        WHERE t.name = %(task_id)s
          AND t.docstatus != 2
          AND (
              EXISTS (
                  SELECT 1
                  FROM `tabToDo` assigned_todo
                  WHERE assigned_todo.reference_type = 'Task'
                    AND assigned_todo.reference_name = t.name
                    AND assigned_todo.allocated_to = %(user)s
                    AND assigned_todo.status != 'Cancelled'
              )
              OR FIND_IN_SET(
                  %(user)s,
                  REPLACE(
                      REPLACE(
                          REPLACE(IFNULL(t._assign, ''), '[', ''),
                          ']', ''
                      ),
                      '"', ''
                  )
              ) > 0
          )
        LIMIT 1
        """,
        {"task_id": task_id, "user": user},
        as_dict=True,
    )
    return rows[0]["name"] if rows else None


if action == "complete":
    task_id = (frappe.form_dict.get("task_id") or "").strip()
    if not task_id:
        frappe.throw("task_id is required.")

    assigned_task_name = get_assigned_task(task_id, current_user)
    if not assigned_task_name:
        frappe.throw("You can complete only tasks assigned to your user.")

    task = frappe.get_doc("Task", assigned_task_name)
    task.status = "Completed"
    task.save(ignore_permissions=True)

    # Close all ToDos for this task that belong to the current user.
    todo_rows = frappe.db.sql(
        """
        SELECT name
        FROM `tabToDo`
        WHERE reference_type = 'Task'
          AND reference_name = %(task_id)s
          AND allocated_to = %(user)s
          AND status != 'Closed'
        """,
        {"task_id": assigned_task_name, "user": current_user},
        as_dict=True,
    )
    for row in todo_rows:
        todo = frappe.get_doc("ToDo", row["name"])
        todo.status = "Closed"
        todo.save(ignore_permissions=True)

    frappe.response["message"] = {
        "status": "success",
        "action": "complete",
        "task_id": assigned_task_name,
        "task_status": task.status,
        "todo_status": "Closed" if todo_rows else None,
    }

elif action == "get":
    task_data = frappe.db.sql(
        """
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
            t.owner AS task_owner_email,
            owner.full_name AS task_owner_name,
            REPLACE(
                REPLACE(
                    REPLACE(IFNULL(t._assign, ''), '[', ''),
                    ']', ''
                ),
                '"', ''
            ) AS assigned_email,
            assignee.full_name AS assigned_user_name,
            latest_todo.allocated_to,
            latest_todo.status AS todo_status,
            latest_todo.priority AS todo_priority,
            latest_todo.date AS todo_date,
            latest_todo.description AS todo_description
        FROM `tabTask` t
        LEFT JOIN `tabUser` owner ON owner.name = t.owner
        LEFT JOIN `tabUser` assignee
            ON assignee.name = REPLACE(
                REPLACE(
                    REPLACE(IFNULL(t._assign, ''), '[', ''),
                    ']', ''
                ),
                '"', ''
            )
        LEFT JOIN (
            SELECT todo.reference_name, todo.allocated_to, todo.status,
                   todo.priority, todo.date, todo.description
            FROM `tabToDo` todo
            INNER JOIN (
                SELECT reference_name, MAX(modified) AS max_modified
                FROM `tabToDo`
                WHERE reference_type = 'Task'
                GROUP BY reference_name
            ) newest
                ON newest.reference_name = todo.reference_name
               AND newest.max_modified = todo.modified
            WHERE todo.reference_type = 'Task'
        ) latest_todo ON latest_todo.reference_name = t.name
        WHERE t.docstatus != 2
          AND (
              EXISTS (
                  SELECT 1
                  FROM `tabToDo` assigned_todo
                  WHERE assigned_todo.reference_type = 'Task'
                    AND assigned_todo.reference_name = t.name
                    AND assigned_todo.allocated_to = %(user)s
              )
              OR FIND_IN_SET(
                  %(user)s,
                  REPLACE(
                      REPLACE(
                          REPLACE(IFNULL(t._assign, ''), '[', ''),
                          ']', ''
                      ),
                      '"', ''
                  )
              ) > 0
          )
        ORDER BY t.creation DESC, t.subject ASC
        LIMIT 1000
        """,
        {"user": current_user},
        as_dict=True,
    )

    for row in task_data:
        description = row.get("task_description") or ""
        description = description.replace("<br />", "\n")
        description = description.replace("<br/>", "\n")
        description = description.replace("<br>", "\n")
        description = description.replace("</p>", "\n")
        description = description.replace("<p>", "")
        description = description.replace("<", "&lt;")
        description = description.replace(">", "&gt;")
        row["task_description"] = description.strip() or None

        todo_description = row.get("todo_description") or ""
        todo_description = todo_description.replace("<br />", "\n")
        todo_description = todo_description.replace("<br/>", "\n")
        todo_description = todo_description.replace("<br>", "\n")
        todo_description = todo_description.replace("</p>", "\n")
        todo_description = todo_description.replace("<p>", "")
        todo_description = todo_description.replace("<", "&lt;")
        todo_description = todo_description.replace(">", "&gt;")
        row["todo_description"] = todo_description.strip() or None

    frappe.response["message"] = {
        "status": "success",
        "action": "get",
        "assigned_to_only": True,
        "assigned_user": current_user,
        # Read the token already stored on this session without calling a
        # helper method that the Server Script sandbox blocks.
        "csrf_token": frappe.session.data.csrf_token,
        "total_tasks": len(task_data),
        "task_data": task_data,
    }

else:
    frappe.throw("Invalid action. Use 'get' or 'complete'.")
