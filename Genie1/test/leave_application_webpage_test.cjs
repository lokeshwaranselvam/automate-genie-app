/* Test-only DOM dependency is installed outside the repository, as for Opportunities. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"),
  path = require("node:path"),
  os = require("node:os"),
  vm = require("node:vm");
const { parseHTML } = require(
  path.join(os.tmpdir(), "genie-opportunities-qa/node_modules/linkedom"),
);
const source = fs.readFileSync(
  path.join(__dirname, "../web_pages/leave-application.html"),
  "utf8",
);
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];
const user = "staff@example.test";
const options = {
  employee: "EMP-1",
  employee_name: "Staff",
  csrf_token: "leave-csrf",
  leave_types: [
    { value: "Annual", label: "Annual Leave" },
    { value: "LWP", label: "Leave Without Pay" },
  ],
  business_policy: { fields: {}, rules: {} },
};
function setup(handler, config = {}) {
  const { document } = parseHTML(
    source.replace(/<script>[\s\S]*?<\/script>/, ""),
  );
  const modal = document.getElementById("la-dialog");
  Object.defineProperty(modal, "open", {
    get() {
      return this.hasAttribute("open");
    },
  });
  modal.showModal = () => modal.setAttribute("open", "");
  modal.close = () => modal.removeAttribute("open");
  const requests = [],
    messages = [];
  let clock = Date.parse("2026-10-31T12:00:00Z");
  class FakeDate extends Date {
    constructor(...args) {
      super(...(args.length ? args : [clock]));
    }
    static now() {
      return clock;
    }
  }
  const window = {
    location: { origin: "https://erp.example.test", assign() {} },
    history: { length: 1, back() {} },
    frappe: { csrf_token: "page-csrf" },
    GenieLeaveApplication: {
      postMessage: (value) => messages.push(JSON.parse(value)),
    },
  };
  const context = vm.createContext({
    document,
    window,
    Date: FakeDate,
    URL,
    URLSearchParams,
    AbortController,
    setTimeout,
    clearTimeout,
    console,
    fetch: async (url, init) => {
      const req = { url: new URL(url), ...init };
      requests.push(req);
      const result = await handler(req);
      if (result instanceof Error) throw result;
      return {
        ok: (result.status || 200) < 400,
        status: result.status || 200,
        json: async () => result.data,
        text: async () => result.html || "",
      };
    },
  });
  const marker = script.indexOf("// LA_BOOTSTRAP");
  assert.ok(marker > 0);
  vm.runInContext(
    script.slice(0, marker) +
      "globalThis.api={state,loadOptions,submit,session,raw,bounds,validate,days,calendarControl,renderForm,back,notifications};})();",
    context,
  );
  return {
    api: context.api,
    document,
    modal,
    requests,
    messages,
    window,
    setClock: (value) => (clock = Date.parse(value)),
  };
}
function standardHandler(req, customOptions = options) {
  if (req.url.pathname.endsWith("get_logged_user"))
    return { data: { message: user } };
  if (
    req.method === "GET" &&
    req.url.pathname.endsWith("create_leave_application_from_mobile")
  )
    return { data: { message: customOptions } };
  throw Error("Unexpected request " + req.url);
}
function fill(env, changes = {}) {
  Object.assign(
    env.api.state.draft,
    {
      leave_type: "Annual",
      from_date: "2026-10-31",
      to_date: "2026-10-31",
      description: "Family leave",
      half_day: false,
    },
    changes,
  );
  env.api.renderForm();
}

test("combined page has only existing leave APIs, no external dependencies or Jinja openers", () => {
  new vm.Script(script);
  assert.ok(!/\{[{%#]/.test(source));
  for (const forbidden of [
    "api_key",
    "<script src=",
    "mobile_opportunity",
    "create_lead",
    "navigator.geolocation",
  ])
    assert.ok(!source.includes(forbidden));
  assert.ok(source.includes("create_leave_application_from_mobile"));
});
test("options and employee come from the existing session API; policy options are retained", async () => {
  const custom = {
    ...options,
    leave_types: [
      ...options.leave_types,
      { value: "Annual", label: "Duplicate" },
    ],
    business_policy: {
      fields: { leave_type: { options: ["Annual"] } },
      rules: {},
    },
  };
  const env = setup((r) => standardHandler(r, custom));
  await env.api.loadOptions();
  assert.equal(env.api.state.options.employee, "EMP-1");
  assert.equal(env.api.state.options.leave_types.length, 1);
  assert.equal(env.api.state.draft.from_date, "2026-10-31");
  for (const req of env.requests) {
    assert.equal(req.credentials, "same-origin");
    assert.equal(req.redirect, "error");
    assert.equal(req.url.search, "");
  }
  assert.match(
    env.document.getElementById("la-content").textContent,
    /Select Leave Type/,
  );
});
test("calendar disables past dates even when ERP earliest date is in the past", async () => {
  const custom = {
    ...options,
    business_policy: {
      fields: {},
      rules: { earliest_date: "2021-01-01", latest_date: "2031-12-31" },
    },
  };
  const env = setup((r) => standardHandler(r, custom));
  await env.api.loadOptions();
  env.document.getElementById("la-from_date").click();
  assert.equal(
    env.document.querySelector('[data-date="2026-10-30"]').disabled,
    true,
  );
  assert.equal(
    env.document.querySelector('[aria-label="Previous month"]').disabled,
    true,
  );
  assert.equal(
    env.document.querySelector('[data-date="2026-10-31"]').disabled,
    false,
  );
});
test("stricter ERP date limits and end date minimum remain enforced", async () => {
  const custom = {
    ...options,
    business_policy: {
      fields: {},
      rules: { earliest_date: "2026-11-02", latest_date: "2026-11-05" },
    },
  };
  const env = setup((r) => standardHandler(r, custom));
  await env.api.loadOptions();
  assert.equal(env.api.state.draft.from_date, "2026-11-02");
  fill(env, { from_date: "2026-11-04", to_date: "2026-11-04" });
  env.document.getElementById("la-to_date").click();
  assert.equal(
    env.document.querySelector('[data-date="2026-11-03"]').disabled,
    true,
  );
  assert.equal(
    env.document.querySelector('[data-date="2026-11-06"]').disabled,
    true,
  );
});
test("past date tampering and an overnight open form cannot send a POST", async () => {
  const env = setup(standardHandler);
  await env.api.loadOptions();
  fill(env, { from_date: "2026-10-30" });
  await env.api.submit();
  assert.match(env.modal.textContent, /Past dates are not allowed/);
  fill(env);
  env.setClock("2026-11-01T12:00:00Z");
  await env.api.submit();
  assert.equal(env.requests.filter((x) => x.method === "POST").length, 0);
});
test("custom leave type choices preserve draft and calendar updates total/end date", async () => {
  const env = setup(standardHandler);
  await env.api.loadOptions();
  env.document.getElementById("la-leave_type").click();
  env.document.querySelector('[data-value="Annual"]').click();
  assert.equal(env.api.state.draft.leave_type, "Annual");
  fill(env, { from_date: "2026-11-01", to_date: "2026-11-01" });
  env.document.getElementById("la-from_date").click();
  env.document.querySelector('[data-date="2026-11-03"]').click();
  assert.equal(env.api.state.draft.to_date, "2026-11-03");
  assert.equal(env.api.days(), 1);
  env.api.state.draft.half_day = true;
  assert.equal(env.api.days(), 0.5);
});
test("one submission uses the same form payload, CSRF and server-confirmed total", async () => {
  let posts = 0,
    payload;
  const env = setup((req) => {
    if (req.method !== "POST") return standardHandler(req);
    posts++;
    payload = new URLSearchParams(req.body);
    assert.equal(req.headers["X-Frappe-CSRF-Token"], "leave-csrf");
    assert.equal(
      req.headers["Content-Type"],
      "application/x-www-form-urlencoded",
    );
    return {
      data: {
        message: { status: "success", name: "HR-LAP-1", total_leave_days: 0.5 },
      },
    };
  });
  await env.api.loadOptions();
  fill(env, { half_day: true });
  await Promise.all([env.api.submit(), env.api.submit()]);
  assert.equal(posts, 1);
  assert.deepEqual(Object.fromEntries(payload), {
    leave_type: "Annual",
    from_date: "2026-10-31",
    to_date: "2026-10-31",
    description: "Family leave",
    half_day: "1",
    csrf_token: "leave-csrf",
  });
  assert.match(env.modal.textContent, /HR-LAP-1 created for 0.5 days/);
  assert.equal(env.api.state.draft.description, "");
  assert.ok(env.messages.some((m) => m.action === "busy" && m.value === true));
  assert.ok(env.messages.some((m) => m.action === "busy" && m.value === false));
});
test("only explicit CSRF failure gets one refresh and retry", async () => {
  let posts = 0;
  const env = setup((req) => {
    if (req.url.pathname === "/app")
      return { html: 'frappe.csrf_token = "fresh-csrf";' };
    if (req.method !== "POST") return standardHandler(req);
    posts++;
    assert.equal(
      req.headers["X-Frappe-CSRF-Token"],
      posts === 1 ? "leave-csrf" : "fresh-csrf",
    );
    return posts === 1
      ? { status: 400, data: { exc_type: "CSRFTokenError" } }
      : { data: { message: { status: "success", name: "HR-LAP-2" } } };
  });
  await env.api.loadOptions();
  fill(env);
  await env.api.submit();
  assert.equal(posts, 2);
});
test("ERP validation popup retains the entered application and is not retried", async () => {
  const env = setup((req) =>
    req.method === "POST"
      ? {
          status: 417,
          data: {
            _server_messages: JSON.stringify([
              JSON.stringify({ message: "<b>No leave balance</b>" }),
            ]),
          },
        }
      : standardHandler(req),
  );
  await env.api.loadOptions();
  fill(env);
  await env.api.submit();
  assert.match(env.modal.textContent, /No leave balance/);
  assert.equal(env.api.state.draft.description, "Family leave");
  assert.equal(env.requests.filter((x) => x.method === "POST").length, 1);
});
test("uncertain network submission is never retried and locks repeat submission", async () => {
  const env = setup((req) =>
    req.method === "POST"
      ? new Error("connection dropped")
      : standardHandler(req),
  );
  await env.api.loadOptions();
  fill(env);
  await env.api.submit();
  assert.equal(env.api.state.uncertain, true);
  assert.match(env.modal.textContent, /uncertain/);
  await env.api.submit();
  await env.api.loadOptions();
  assert.equal(env.requests.filter((x) => x.method === "POST").length, 1);
  assert.equal(env.api.state.draft.description, "Family leave");
});
test("changed session clears private form values and prevents submission", async () => {
  let actor = user;
  const env = setup((req) =>
    req.url.pathname.endsWith("get_logged_user")
      ? { data: { message: actor } }
      : standardHandler(req),
  );
  await env.api.loadOptions();
  fill(env);
  actor = "other@example.test";
  await env.api.submit();
  assert.equal(env.api.state.stopped, true);
  assert.equal(env.api.state.draft.description, "");
  assert.equal(env.requests.filter((x) => x.method === "POST").length, 0);
});
test("readonly defaults, hidden fields and half day policy remain active", async () => {
  const custom = {
    ...options,
    business_policy: {
      fields: {
        description: {
          read_only: true,
          default: "Policy reason",
          required: true,
        },
        leave_type: { read_only: true, default: "Annual" },
        half_day: { visible: false },
      },
      rules: { half_day_allowed: false },
    },
  };
  const env = setup((r) => standardHandler(r, custom));
  await env.api.loadOptions();
  assert.equal(env.document.getElementById("la-description").readOnly, true);
  assert.equal(env.document.getElementById("la-leave_type").disabled, true);
  assert.equal(env.api.state.draft.description, "Policy reason");
  assert.equal(env.api.state.draft.leave_type, "Annual");
  assert.equal(env.document.getElementById("la-half_day"), null);
});
test("invalid readonly past dates fail closed instead of being selectable", async () => {
  const custom = {
    ...options,
    business_policy: {
      fields: { from_date: { read_only: true, default: "2026-10-30" } },
      rules: {},
    },
  };
  const env = setup((r) => standardHandler(r, custom));
  await env.api.loadOptions();
  assert.match(
    env.document.getElementById("la-content").textContent,
    /read-only date default/,
  );
  assert.equal(env.document.getElementById("la-submit"), null);
});
test("max days, reason length and required reason are checked", async () => {
  const custom = {
    ...options,
    business_policy: {
      fields: { description: { required: true, max_length: 10 } },
      rules: { max_days: 2 },
    },
  };
  const env = setup((r) => standardHandler(r, custom));
  await env.api.loadOptions();
  fill(env, { description: "" });
  assert.throws(() => env.api.validate(), /Reason is required/);
  env.api.state.draft.description = "A reason that is long";
  assert.throws(() => env.api.validate(), /too long/);
  env.api.state.draft.description = "Family";
  env.api.state.draft.to_date = "2026-11-03";
  assert.throws(() => env.api.validate(), /number of days/);
});
test("Back and Notifications use the native bridge and stay blocked during submission", () => {
  const env = setup(standardHandler);
  env.api.back();
  env.api.notifications();
  assert.deepEqual(env.messages, [
    { action: "close" },
    { action: "notifications" },
  ]);
  env.api.state.busy = true;
  env.api.back();
  env.api.notifications();
  assert.equal(env.messages.length, 2);
});
test("external API origins are rejected before any request", async () => {
  const env = setup(standardHandler);
  await assert.rejects(
    env.api.raw("https://outside.example/collect"),
    /Invalid ERP/,
  );
  assert.equal(env.requests.length, 0);
});

test("Back dismisses the result popup before leaving the form", async () => {
  const env = setup(standardHandler);
  await env.api.loadOptions();
  fill(env, { description: "" });
  await env.api.submit();
  assert.equal(env.modal.open, true);
  env.api.back();
  assert.equal(env.modal.open, false);
  assert.equal(env.messages.length, 0);
  env.api.back();
  assert.deepEqual(env.messages, [{ action: "close" }]);
});

test("a confirmed POST followed by a failed session check cannot be submitted twice", async () => {
  let saved = false;
  const env = setup((req) => {
    if (req.method === "POST") {
      saved = true;
      return { data: { message: { status: "success", name: "HR-LAP-SAVED" } } };
    }
    if (saved && req.url.pathname.endsWith("get_logged_user")) {
      return new Error("connection dropped after saving");
    }
    return standardHandler(req);
  });
  await env.api.loadOptions();
  fill(env);
  await env.api.submit();
  assert.equal(env.api.state.uncertain, true);
  await env.api.submit();
  assert.equal(env.requests.filter((req) => req.method === "POST").length, 1);
});

test("HTTP 400 ERP validation messages remain readable and preserve the draft", async () => {
  const env = setup((req) =>
    req.method === "POST"
      ? {
          status: 400,
          data: {
            _server_messages: JSON.stringify([
              JSON.stringify({
                message: "Set a Leave Approver before applying.",
              }),
            ]),
          },
        }
      : standardHandler(req),
  );
  await env.api.loadOptions();
  fill(env);
  await env.api.submit();
  assert.match(env.modal.textContent, /Set a Leave Approver/);
  assert.equal(env.api.state.draft.description, "Family leave");
  assert.equal(env.requests.filter((req) => req.method === "POST").length, 1);
});
