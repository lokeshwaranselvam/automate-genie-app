/* Local DOM/API contract checks. Install the test-only DOM package outside the repo:
   npm install --prefix "$env:TEMP\genie-opportunities-qa" linkedom --no-audit --no-fund
   node test/opportunities_webpage_test.cjs
*/
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const vm = require("node:vm");
const { parseHTML } = require(
  path.join(os.tmpdir(), "genie-opportunities-qa/node_modules/linkedom"),
);
const source = fs.readFileSync(
  path.join(__dirname, "../web_pages/opportunities.html"),
  "utf8",
);
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];

function setup(handler) {
  const { document } = parseHTML(
    source.replace(/<script>[\s\S]*?<\/script>/, ""),
  );
  const create = document.createElement.bind(document);
  document.createElement = (name) => {
    const node = create(name);
    if (name === "select")
      Object.defineProperty(node, "value", { value: "", writable: true });
    return node;
  };
  const modal = document.getElementById("go-dialog");
  Object.defineProperty(modal, "open", {
    get() {
      return this.hasAttribute("open");
    },
  });
  modal.showModal = () => modal.setAttribute("open", "");
  modal.close = () => modal.removeAttribute("open");
  const requests = [],
    location = { origin: "https://erp.example.test", hash: "", reload() {} };
  const window = {
    location,
    frappe: { csrf_token: "csrf-a" },
    addEventListener() {},
    GenieOpportunities: { postMessage() {} },
  };
  const context = vm.createContext({
    document,
    window,
    Event: document.defaultView.Event,
    URL,
    URLSearchParams,
    AbortController,
    setTimeout,
    clearTimeout,
    console,
    fetch: async (url, options) => {
      const request = { url: new URL(url), ...options };
      requests.push(request);
      const result = await handler(request);
      if (result instanceof Error) throw result;
      return {
        ok: (result.status || 200) < 400,
        status: result.status || 200,
        json: async () => result.data,
        text: async () => result.html || "",
      };
    },
  });
  const marker = script.indexOf("// GO_BOOTSTRAP");
  assert.ok(marker > 0);
  const testScript =
    script.slice(0, marker) +
    "globalThis.api = {state,session,raw,write,assertOwner,formatTime,plain,listShell,loadList,renderDetail,editDialog,ownerDialog,loadDetail,callContact};})();";
  vm.runInContext(testScript, context, { filename: "opportunities.html" });
  return { api: context.api, document, window, requests, modal };
}
const user = "sales@example.test";
const sessionReply = { data: { message: user } };
const doc = {
  name: "OPP-1",
  owner: user,
  opportunity_owner: user,
  status: "Open",
  modified: "2026-10-31 12:00:00",
  customer_name: "Customer One",
};

test("HTML has only Opportunity scope and no Lead creation or GPS API", () => {
  assert.ok(!source.includes("create_lead_from_mobile"));
  assert.ok(!source.includes("navigator.geolocation"));
  assert.ok(!source.includes("api_key"));
  assert.ok(!source.includes("<script src="));
  assert.ok(
    !/\{[{%#]/.test(source),
    "HTML must remain safe for Frappe Jinja rendering",
  );
  new vm.Script(script);
});

test("session comes from ERP, never from URL; changing account clears records", async () => {
  let current = user;
  const env = setup(async () => ({ data: { message: current } }));
  env.window.location.hash = "#user=attacker@example.test";
  assert.equal(await env.api.session(), user);
  env.api.state.rows = [doc];
  current = "other@example.test";
  await assert.rejects(env.api.session(), /session changed/i);
  assert.equal(env.api.state.stopped, true);
  assert.equal(env.api.state.rows.length, 0);
});

test("list delegates owner visibility, phone/status and pagination to the Server Script", async () => {
  let start = 0;
  const env = setup(async (r) => {
    if (r.url.pathname.endsWith("get_logged_user")) return sessionReply;
    assert.equal(r.credentials, "same-origin");
    assert.equal(r.redirect, "error");
    assert.equal(r.url.pathname, "/api/method/mobile_opportunity_policy");
    assert.equal(r.url.searchParams.get("action"), "list");
    assert.equal(r.url.searchParams.get("phone"), "987");
    assert.equal(r.url.searchParams.get("status"), "Follow-up");
    assert.equal(r.url.searchParams.has("user"), false);
    start = Number(r.url.searchParams.get("start"));
    const items = Array.from({ length: start ? 1 : 50 }, (_, i) => ({
      ...doc,
      name: "OPP-" + (i + start),
      opportunity_owner: "other@example.test",
    }));
    return {
      data: {
        message: {
          current_user: user,
          items,
          has_more: !start,
          next_start: start + items.length,
        },
      },
    };
  });
  env.api.state.phone = "987";
  env.api.state.status = "Follow-up";
  env.api.listShell();
  await env.api.loadList();
  assert.equal(env.api.state.rows.length, 50);
  assert.equal(env.api.state.more, true);
  await env.api.loadList(true);
  assert.equal(start, 50);
  assert.equal(env.api.state.rows.length, 51);
  assert.equal(env.api.state.more, false);
});

test("list rejects a response for a different session", async () => {
  const env = setup(async (r) =>
    r.url.pathname.endsWith("get_logged_user")
      ? sessionReply
      : {
          data: {
            message: {
              current_user: "other@example.test",
              items: [doc],
              has_more: false,
              next_start: 1,
            },
          },
        },
  );
  env.api.listShell();
  await env.api.loadList();
  assert.equal(env.api.state.rows.length, 0);
  assert.match(
    env.document.getElementById("go-list-end").textContent,
    /session/,
  );
});

test("field owner can read details but cannot start edits or calls", async () => {
  const env = setup(async (r) => {
    if (r.url.pathname.endsWith("get_logged_user")) return sessionReply;
    if (r.url.pathname.endsWith("get_value"))
      return { data: { message: { full_name: "Creator" } } };
    assert.equal(r.url.pathname, "/api/method/mobile_opportunity_policy");
    assert.equal(r.url.searchParams.get("action"), "detail");
    return {
      data: {
        message: {
          current_user: user,
          document: {
            ...doc,
            opportunity_owner: "other@example.test",
            phone: "9876543210",
          },
          can_edit: false,
        },
      },
    };
  });
  env.window.location.hash = "#opportunity=OPP-1";
  await env.api.loadDetail("OPP-1");
  assert.equal(env.api.state.document.name, "OPP-1");
  assert.ok(
    !env.document
      .getElementById("go-content")
      .textContent.includes("Edit status"),
  );
  assert.equal(
    env.document.querySelector('[aria-label="Edit Opportunity Owner"]'),
    null,
  );
  const requests = env.requests.length;
  await env.api.editDialog();
  await env.api.ownerDialog();
  await env.api.callContact("9876543210");
  assert.equal(env.requests.length, requests);
  assert.equal(env.modal.open, false);
});

test("writes use CSRF and only explicit CSRF rejection is retried", async () => {
  let posts = 0;
  const env = setup(async (r) => {
    if (r.url.pathname.endsWith("get_logged_user")) return sessionReply;
    if (r.url.pathname === "/app")
      return { html: 'frappe.csrf_token = "csrf-b";' };
    posts++;
    assert.equal(
      r.headers["X-Frappe-CSRF-Token"],
      posts === 1 ? "csrf-a" : "csrf-b",
    );
    assert.equal(
      JSON.parse(r.body).csrf_token,
      posts === 1 ? "csrf-a" : "csrf-b",
    );
    return posts === 1
      ? { status: 400, data: { exc_type: "CSRFTokenError" } }
      : { data: { message: { status: "success" } } };
  });
  await env.api.session();
  await env.api.write("/api/method/mobile_opportunity_policy", {
    action: "save",
  });
  assert.equal(posts, 2);
});

test("network failure on a write is uncertain and never retried", async () => {
  let posts = 0;
  const env = setup(async (r) => {
    if (r.url.pathname.endsWith("get_logged_user")) return sessionReply;
    posts++;
    return new Error("connection lost");
  });
  await env.api.session();
  await assert.rejects(
    env.api.write("/api/method/mobile_opportunity_policy", { action: "save" }),
    (error) => error.uncertain === true,
  );
  assert.equal(posts, 1);
});

test("external endpoints cannot receive requests", async () => {
  const env = setup(async () => sessionReply);
  await assert.rejects(
    env.api.raw("https://outside.example/api/method/test"),
    /Invalid ERP request/,
  );
  assert.equal(env.requests.length, 0);
});

test("details retain latest three notes and right-side audit; excluded fields stay hidden", () => {
  const env = setup(async () => sessionReply);
  const data = {
    ...doc,
    opportunity_type: "SHOULD_NOT_APPEAR",
    probability: 97,
    notes: Array.from({ length: 4 }, (_, i) => ({
      name: "NOTE-" + i,
      note: "<p>Note " + i + "</p>",
      added_by: user,
      added_on: `2026-10-${20 + i} 12:37:00`,
    })),
  };
  const original = JSON.stringify(data);
  env.api.renderDetail(data, "Sales User");
  const text = env.document.getElementById("go-content").textContent;
  assert.ok(!text.includes("SHOULD_NOT_APPEAR"));
  assert.ok(!text.includes("Probability"));
  assert.ok(!text.includes("Note 0"));
  assert.ok(text.includes("Note 3"));
  assert.ok(text.includes("23 Oct 2026, 12:37 PM"));
  assert.equal(env.document.querySelectorAll(".go-note-audit").length, 3);
  assert.equal(JSON.stringify(data), original);
});

test("display never inserts server HTML or a script into the page", () => {
  const env = setup(async () => sessionReply);
  env.api.renderDetail(
    {
      ...doc,
      customer_name: "<img src=x onerror=alert(1)>",
      notes: [{ note: "<script>alert(1)</script><p>Plain note</p>" }],
    },
    "Sales",
  );
  assert.equal(
    env.document.getElementById("go-content").querySelectorAll("script,img")
      .length,
    0,
  );
});

test("owner choices use existing scoped endpoint and no browser-side User lookup", async () => {
  const env = setup(async (r) => {
    assert.equal(r.url.pathname, "/api/method/mobile_opportunity_policy");
    assert.equal(r.url.searchParams.get("action"), "owner_options");
    assert.equal(r.url.searchParams.get("name"), "OPP-1");
    return {
      data: {
        message: {
          current_user: user,
          options: [{ value: "next@example.test", label: "Next User" }],
        },
      },
    };
  });
  env.api.state.user = user;
  env.api.state.document = doc;
  await env.api.ownerDialog();
  assert.match(env.modal.textContent, /Next User/);
});

const metadata = {
  docs: [
    {
      name: "Opportunity",
      fields: [
        {
          fieldname: "status",
          fieldtype: "Select",
          options: "Open\nFollow-up\nDemo",
        },
        { fieldname: "notes", fieldtype: "Table", options: "CRM Note" },
        {
          fieldname: "custom_next_followup_date",
          label: "Next Followup Date",
          fieldtype: "Date",
        },
      ],
    },
    {
      name: "CRM Note",
      fields: [{ fieldname: "note", fieldtype: "Text Editor" }],
    },
  ],
};
const settings = {
  message: {
    current_user: user,
    editable_statuses: ["Open", "Follow-up", "Demo"],
    status_transitions: {},
    followup_policy: { allow_past: false, earliest_date: "2026-10-31" },
    business_policy: {
      fields: { status: {}, note: {}, followup_date: {} },
      rules: {
        note_on_status_change: true,
        note_on_followup_change: true,
        preserve_note_history: true,
        dependencies: [],
      },
    },
  },
};
const tick = () => new Promise((resolve) => setImmediate(resolve));
const clickSave = (env) =>
  [...env.modal.querySelectorAll("button")]
    .find((x) => x.textContent === "Save")
    .click();

test("status edit requires a new note then sends the unchanged existing notes and revision", async () => {
  const original = {
    ...doc,
    custom_next_followup_date: "2026-10-31",
    notes: [
      {
        name: "NOTE-OLD",
        note: "History",
        added_by: "original@example.test",
        added_on: "2026-10-20 09:00:00",
      },
    ],
  };
  let payload,
    saved = false;
  const env = setup(async (r) => {
    if (r.url.pathname.endsWith("get_logged_user")) return sessionReply;
    if (r.url.pathname.endsWith("getdoctype")) return { data: metadata };
    if (r.url.pathname === "/api/resource/Opportunity/OPP-1")
      return {
        data: { data: { ...original, status: saved ? "Follow-up" : "Open" } },
      };
    if (r.url.pathname.endsWith("get_value"))
      return { data: { message: { full_name: "Sales" } } };
    if (r.method === "POST") {
      payload = JSON.parse(r.body);
      saved = true;
      return { data: { data: { ...original, status: "Follow-up" } } };
    }
    return { data: settings };
  });
  env.window.location.hash = "#opportunity=OPP-1";
  env.api.state.user = user;
  env.api.state.document = original;
  await env.api.editDialog();
  env.document.getElementById("go-edit-status").value = "Follow-up";
  clickSave(env);
  await tick();
  assert.equal(payload, undefined);
  const warning = env.document.getElementById("go-warning");
  assert.equal(warning.hasAttribute("open"), true);
  assert.match(warning.textContent, /Note required/);
  assert.equal(env.modal.open, true);
  warning.querySelector("button").click();
  assert.equal(warning.hasAttribute("open"), false);
  assert.equal(
    env.document.getElementById("go-edit-status").value,
    "Follow-up",
  );
  env.document.getElementById("go-edit-note").value = "Call <tomorrow>";
  clickSave(env);
  await tick();
  await tick();
  assert.equal(payload.action, "save");
  assert.equal(payload.modified, doc.modified);
  assert.equal(payload.changes.status, "Follow-up");
  assert.deepEqual(payload.changes.notes[0], original.notes[0]);
  assert.equal(payload.changes.notes[1].note, "<p>Call &lt;tomorrow&gt;</p>");
  assert.equal(payload.changes.notes[1].added_by, undefined);
  assert.equal(env.modal.open, false);
});

test("a stale Opportunity is not saved", async () => {
  let posts = 0;
  const env = setup(async (r) => {
    if (r.url.pathname.endsWith("get_logged_user")) return sessionReply;
    if (r.url.pathname.endsWith("getdoctype")) return { data: metadata };
    if (r.url.pathname.includes("/api/resource/"))
      return { data: { data: { ...doc, modified: "newer" } } };
    if (r.method === "POST") posts++;
    return { data: settings };
  });
  env.api.state.user = user;
  env.api.state.document = doc;
  await env.api.editDialog();
  env.document.getElementById("go-edit-note").value = "A new note";
  clickSave(env);
  await tick();
  await tick();
  assert.equal(posts, 0);
  assert.match(env.modal.textContent, /changed/);
});

test("owner transfer posts only the owner action and leaves the old detail", async () => {
  let payload;
  const env = setup(async (r) => {
    if (r.url.pathname.endsWith("get_logged_user")) return sessionReply;
    if (r.method === "POST") {
      payload = JSON.parse(r.body);
      return {
        data: {
          message: {
            status: "success",
            current_user: user,
            name: doc.name,
            opportunity_owner: "next@example.test",
          },
        },
      };
    }
    return {
      data: {
        message: {
          current_user: user,
          options: [{ value: "next@example.test", label: "Next User" }],
        },
      },
    };
  });
  env.api.state.user = user;
  env.api.state.document = doc;
  env.window.location.hash = "#opportunity=OPP-1";
  await env.api.ownerDialog();
  env.modal.querySelector(".go-owner-choice").click();
  clickSave(env);
  clickSave(env);
  await tick();
  await tick();
  assert.deepEqual(payload, {
    action: "change_owner",
    name: doc.name,
    modified: doc.modified,
    new_owner: "next@example.test",
    csrf_token: "csrf-a",
  });
  assert.equal(env.window.location.hash, "");
  assert.equal(env.api.state.document, null);
  assert.equal(env.requests.filter((x) => x.method === "POST").length, 1);
});

test("custom status picker changes the existing value without a native select", async () => {
  const env = setup(async (r) =>
    r.url.pathname.endsWith("getdoctype")
      ? { data: metadata }
      : { data: settings },
  );
  env.api.state.user = user;
  env.api.state.document = { ...doc, custom_next_followup_date: "2026-10-31" };
  await env.api.editDialog();
  assert.equal(
    env.modal.querySelectorAll('select,input[type="date"]').length,
    0,
  );
  env.document.getElementById("go-edit-status-toggle").click();
  const panel = env.document.getElementById("go-edit-status-options");
  assert.equal(panel.hidden, false);
  panel.querySelector('[data-value="Follow-up"]').click();
  assert.equal(
    env.document.getElementById("go-edit-status").value,
    "Follow-up",
  );
  assert.match(
    env.document.getElementById("go-edit-status-toggle").textContent,
    /Follow-up/,
  );
  assert.equal(panel.hidden, true);
});

test("custom calendar respects the ERP minimum and submits the same ISO date field", async () => {
  let payload;
  const original = {
    ...doc,
    custom_next_followup_date: "2026-10-31",
    notes: [],
  };
  const env = setup(async (r) => {
    if (r.url.pathname.endsWith("get_logged_user")) return sessionReply;
    if (r.url.pathname.endsWith("getdoctype")) return { data: metadata };
    if (r.url.pathname.includes("/api/resource/"))
      return { data: { data: original } };
    if (r.url.pathname.endsWith("get_value"))
      return { data: { message: { full_name: "Sales" } } };
    if (r.method === "POST") {
      payload = JSON.parse(r.body);
      return {
        data: {
          data: { ...original, custom_next_followup_date: "2026-11-05" },
        },
      };
    }
    return { data: settings };
  });
  env.api.state.user = user;
  env.api.state.document = original;
  env.window.location.hash = "#opportunity=OPP-1";
  await env.api.editDialog();
  env.document.getElementById("go-edit-date-toggle").click();
  const calendar = env.document.getElementById("go-edit-date-calendar");
  assert.equal(calendar.hidden, false);
  assert.equal(
    calendar.querySelector('[data-date="2026-10-30"]').disabled,
    true,
  );
  assert.equal(
    calendar.querySelector('[data-date="2026-10-31"]').disabled,
    false,
  );
  assert.equal(calendar.querySelectorAll("select").length, 0);
  calendar.querySelector('[aria-label="Next month"]').click();
  calendar.querySelector('[data-date="2026-11-05"]').click();
  assert.equal(env.document.getElementById("go-edit-date").value, "2026-11-05");
  assert.match(
    env.document.getElementById("go-edit-date-toggle").textContent,
    /05 Nov 2026/,
  );
  assert.equal(calendar.hidden, true);
  env.document.getElementById("go-edit-note").value =
    "Follow-up moved after customer call";
  clickSave(env);
  await tick();
  await tick();
  assert.equal(payload.changes.custom_next_followup_date, "2026-11-05");
  assert.equal(payload.changes.status, undefined);
  assert.equal(
    payload.changes.notes[0].note,
    "<p>Follow-up moved after customer call</p>",
  );
});

test("custom calendar includes February 29 in a leap year", async () => {
  const env = setup(async (r) =>
    r.url.pathname.endsWith("getdoctype")
      ? { data: metadata }
      : { data: settings },
  );
  env.api.state.user = user;
  env.api.state.document = { ...doc, custom_next_followup_date: "2028-02-28" };
  await env.api.editDialog();
  env.document.getElementById("go-edit-date-toggle").click();
  const leap = env.document.querySelector('[data-date="2028-02-29"]');
  assert.ok(leap);
  assert.equal(leap.disabled, false);
  leap.click();
  assert.equal(env.document.getElementById("go-edit-date").value, "2028-02-29");
});

test("custom controls remain read-only when the ERP policy says so; icons are inline SVG", async () => {
  const readonly = JSON.parse(JSON.stringify(settings));
  readonly.message.business_policy.fields.status.read_only = true;
  readonly.message.business_policy.fields.followup_date.read_only = true;
  const env = setup(async (r) =>
    r.url.pathname.endsWith("getdoctype")
      ? { data: metadata }
      : { data: readonly },
  );
  env.api.state.user = user;
  env.api.state.document = { ...doc, custom_next_followup_date: "2026-10-31" };
  env.api.renderDetail(env.api.state.document, "Sales");
  assert.ok(env.document.querySelectorAll(".go-badge svg").length > 0);
  await env.api.editDialog();
  assert.equal(
    env.document.getElementById("go-edit-status-toggle").disabled,
    true,
  );
  assert.equal(
    env.document.getElementById("go-edit-date-toggle").disabled,
    true,
  );
  assert.ok(
    env.document.getElementById("go-edit-date-toggle").querySelector("svg"),
  );
});

test("selecting Demo shows the configured Create Event popup and preserves the editor", async () => {
  const withDependency = JSON.parse(JSON.stringify(settings));
  const message =
    "Create an event first for this Opportunity before saving Demo.";
  withDependency.message.business_policy.rules.dependencies = [
    { statuses: ["Demo"], message },
  ];
  const env = setup(async (r) =>
    r.url.pathname.endsWith("getdoctype")
      ? { data: metadata }
      : { data: withDependency },
  );
  env.api.state.user = user;
  env.api.state.document = { ...doc, custom_next_followup_date: "2026-10-31" };
  await env.api.editDialog();
  env.document.getElementById("go-edit-note").value = "Keep this draft";
  env.document.getElementById("go-edit-status-toggle").click();
  env.document.querySelector('[data-value="Demo"]').click();
  const warning = env.document.getElementById("go-warning");
  assert.equal(warning.hasAttribute("open"), true);
  assert.match(warning.textContent, /Create an event first/);
  assert.equal(env.modal.textContent.includes(message), false);
  assert.equal(env.modal.open, true);
  assert.equal(env.document.getElementById("go-edit-status").value, "Demo");
  warning.querySelector("button").click();
  assert.equal(warning.hasAttribute("open"), false);
  assert.equal(
    env.document.getElementById("go-edit-note").value,
    "Keep this draft",
  );
  assert.equal(env.requests.filter((r) => r.method === "POST").length, 0);
});

test("server Create Event rejection is shown in a popup without discarding note or date", async () => {
  const withDependency = JSON.parse(JSON.stringify(settings));
  const message =
    "Create an event first for this Opportunity before saving Demo.";
  withDependency.message.business_policy.rules.dependencies = [
    { statuses: ["Demo"], message },
  ];
  const original = { ...doc, custom_next_followup_date: "2026-10-31" };
  let writes = 0;
  const env = setup(async (r) => {
    if (r.url.pathname.endsWith("get_logged_user")) return sessionReply;
    if (r.url.pathname.endsWith("getdoctype")) return { data: metadata };
    if (r.url.pathname.includes("/api/resource/"))
      return { data: { data: original } };
    if (r.method === "POST") {
      writes++;
      return {
        status: 417,
        data: {
          _server_messages: JSON.stringify([JSON.stringify({ message })]),
        },
      };
    }
    return { data: withDependency };
  });
  env.api.state.user = user;
  env.api.state.document = original;
  await env.api.editDialog();
  env.document.getElementById("go-edit-status").value = "Demo";
  env.document.getElementById("go-edit-note").value =
    "Customer requested a demo";
  clickSave(env);
  await tick();
  await tick();
  const warning = env.document.getElementById("go-warning");
  assert.equal(warning.hasAttribute("open"), true);
  assert.match(warning.textContent, /Create an event first/);
  assert.equal(writes, 1);
  assert.equal(env.modal.open, true);
  warning.querySelector("button").click();
  assert.equal(
    env.document.getElementById("go-edit-note").value,
    "Customer requested a demo",
  );
  assert.equal(env.document.getElementById("go-edit-date").value, "2026-10-31");
});
