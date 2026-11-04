const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"),
  path = require("node:path");
const { chromium } = require("playwright");
const asset = path.resolve(__dirname, "../web_pages/lead-creation.html");
const data = {
  lead_owner: "sales@example.test",
  csrf_token: "test-csrf",
  source_options: ["Website", "Referral"],
  product_category_options: ["Doors", "Windows"],
  customer_category_options: ["B2B", "B2C"],
  location_fields: {
    custom_citytown: { fieldtype: "Select", options: ["Chennai", "Madurai"] },
    custom_district: {
      fieldtype: "Select",
      options: ["Chennai - TN", "Madurai - TN"],
    },
  },
  business_policy: { fields: {}, rules: {} },
};
let browser;
before(async () => {
  browser = await chromium.launch({
    headless: true,
    ...(process.platform === "win32"
      ? {
          executablePath:
            process.env.EDGE_BINARY ||
            "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
        }
      : {}),
  });
});
after(async () => {
  await browser?.close();
});
async function setup(
  handler,
  options = data,
  width = 360,
  native = false,
  cookieUser = "sales@example.test",
  appUser = "sales@example.test",
) {
  const page = await browser.newPage({
    viewport: { width, height: 1044 },
    deviceScaleFactor: 2,
  });
  const calls = [],
    errors = [],
    requests = [],
    nativeMessages = [];
  let currentUser = cookieUser;
  page.on("pageerror", (error) => errors.push(error));
  await page.route("https://erp.example.test/**", async (route) => {
    const request = route.request(),
      url = new URL(request.url());
    if (url.pathname === "/create_lead_from_mobile")
      return route.fulfill({
        contentType: "text/html",
        body:
          '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><nav id="erp-nav">ERP navigation</nav>' +
          fs.readFileSync(asset, "utf8") +
          "</body></html>",
      });
    requests.push({
      url: url.href,
      method: request.method(),
      headers: request.headers(),
      body: request.postData(),
    });
    if (url.pathname.endsWith("get_logged_user"))
      return route.fulfill({ json: { message: currentUser } });
    if (url.pathname === "/app")
      return route.fulfill({
        contentType: "text/html",
        body: '<script>frappe.csrf_token = "fresh-token";</script>',
      });
    assert.equal(url.pathname, "/api/method/create_lead_from_mobile");
    const args =
      request.method() === "POST"
        ? Object.fromEntries(new URLSearchParams(request.postData()))
        : url.searchParams.get("view") === "location_options"
          ? {
              field: url.searchParams.get("fieldname"),
              query: url.searchParams.get("txt"),
            }
          : {};
    const action =
      request.method() === "POST"
        ? "submit"
        : url.searchParams.get("view") === "location_options"
          ? "search"
          : "options";
    const call = { action, args };
    calls.push(call);
    try {
      const result = handler
        ? await handler(call)
        : action === "options"
          ? options
          : action === "submit"
            ? true
            : [];
      if (result?.$abort) return route.abort("failed");
      if (result?.$http)
        return route.fulfill({ status: result.status, json: result.data });
      const message =
        action === "options"
          ? result
          : action === "search"
            ? { options: result.map((value) => ({ value })) }
            : result === true
              ? { status: "success", name: "LEAD-1" }
              : result;
      return route.fulfill({ json: { message } });
    } catch (error) {
      return route.fulfill({
        status: 417,
        json: {
          _server_messages: JSON.stringify([
            JSON.stringify({ message: error.message }),
          ]),
        },
      });
    }
  });
  if (native) {
    await page.exposeFunction("nativeLeadRequest", async (request) => {
      nativeMessages.push(request);
      if (request.action === "ready") return appUser;
      if (request.action === "location")
        return handler ? handler(request) : "Chennai GPS address";
      return null;
    });
    await page.addInitScript(() => {
      window.GenieLead = {
        postMessage(raw) {
          const request = JSON.parse(raw);
          window
            .nativeLeadRequest(request)
            .then((result) => {
              if (request.action === "ready" && result)
                window.dispatchEvent(
                  new CustomEvent("genie-lead-session", {
                    detail: { user: result },
                  }),
                );
              else if (request.id)
                window.LeadForm.receive({ id: request.id, result });
            })
            .catch((error) => {
              if (request.id)
                window.LeadForm.receive({
                  id: request.id,
                  error: error.message,
                });
            });
        },
      };
    });
  }
  await page.goto("https://erp.example.test/create_lead_from_mobile");
  if (!native || appUser)
    await page.locator("#loading").waitFor({ state: "hidden" });
  return {
    page,
    calls,
    errors,
    requests,
    nativeMessages,
    setUser(value) {
      currentUser = value;
    },
  };
}
async function choose(page, name, value) {
  await page.locator("#" + name).fill(value);
  await page.getByRole("option", { name: value, exact: true }).click();
}
async function fill(page) {
  await page.locator("#first_name").fill("Customer One");
  await page.locator("#mobile_no").fill("9876543210");
  await page.locator("#same-phone").check();
  await choose(page, "custom_product_enquired", "Doors");
  await choose(page, "source", "Website");
  await choose(page, "custom_citytown", "Chennai");
  await choose(page, "custom_district", "Chennai - TN");
  await page.locator("#custom_requirement").fill("Residential project");
}
test("combined ERP page uses the existing API and no external dependencies or credentials", () => {
  const source = fs.readFileSync(asset, "utf8");
  assert.ok(source.includes("/api/method/create_lead_from_mobile"));
  assert.ok(source.includes('credentials: "same-origin"'));
  assert.ok(
    !/<script\s+src=|<link\b|api_secret|sid=|connect-src 'none'/i.test(source),
  );
  assert.ok(!/<html\b|<head\b|<body\b|Content-Security-Policy/i.test(source));
});
test("same field order, spacing, colors, labels and narrow phone layout", async () => {
  const { page, errors } = await setup();
  try {
    assert.deepEqual(await page.locator("label.caption").allTextContents(), [
      "Customer Name *",
      "Phone Number *",
      "WhatsApp Number *",
      "Product Enquired *",
      "Lead Source *",
      "Customer Category",
      "City/Town *",
      "District *",
      "Location",
      "Requirement *",
    ]);
    assert.equal(
      await page.evaluate(
        () => document.getElementById("lc-app").scrollWidth <= innerWidth,
      ),
      true,
    );
    const metrics = await page.evaluate(() => ({
      padding: getComputedStyle(document.querySelector(".lc-content")).padding,
      input: getComputedStyle(document.getElementById("first_name"))
        .borderRadius,
      gradient: getComputedStyle(document.getElementById("submit"))
        .backgroundImage,
    }));
    assert.equal(metrics.padding, "13px 20px 24px");
    assert.equal(metrics.input, "9px");
    assert.match(metrics.gradient, /rgb\(0, 85, 255\)/);
    await page.screenshot({
      path: path.resolve(
        __dirname,
        "../build/lead_creation_preview/webview-form.png",
      ),
      fullPage: true,
    });
    await page.setViewportSize({ width: 320, height: 740 });
    assert.equal(
      await page.evaluate(
        () => document.getElementById("lc-app").scrollWidth <= innerWidth,
      ),
      true,
    );
    assert.deepEqual(errors, []);
  } finally {
    await page.close();
  }
});
test("WhatsApp copy keeps syncing and restores the separate number when unchecked", async () => {
  const { page } = await setup();
  try {
    await page.locator("#whatsapp_no").fill("9123456789");
    await page.locator("#mobile_no").fill("9876543210");
    await page.locator("#same-phone").check();
    assert.equal(await page.locator("#whatsapp_no").inputValue(), "9876543210");
    assert.equal(
      await page.locator("#whatsapp_no").getAttribute("readonly"),
      "",
    );
    await page.locator("#mobile_no").fill("9999999999");
    assert.equal(await page.locator("#whatsapp_no").inputValue(), "9999999999");
    await page.locator("#same-phone").uncheck();
    assert.equal(await page.locator("#whatsapp_no").inputValue(), "9123456789");
  } finally {
    await page.close();
  }
});
test("required, configured choices and WhatsApp format block invalid submission", async () => {
  const { page, calls } = await setup();
  try {
    await page.locator("#submit").click();
    assert.equal(
      await page.locator("#first_name-error").textContent(),
      "Enter the customer name.",
    );
    await fill(page);
    await page.locator("#same-phone").uncheck();
    await page.locator("#whatsapp_no").fill("bad number");
    await page.locator("#submit").click();
    assert.match(
      await page.locator("#whatsapp_no-error").textContent(),
      /valid WhatsApp/,
    );
    await page.locator("#whatsapp_no").fill("9876543210");
    await page.locator("#source").fill("Unconfigured");
    await page.locator("#submit").click();
    assert.match(
      await page.locator("#source-error").textContent(),
      /configured options/,
    );
    assert.equal(calls.filter((x) => x.action === "submit").length, 0);
  } finally {
    await page.close();
  }
});
test("one submission preserves payload and selections, clears only existing reset fields", async () => {
  let release;
  const { page, calls } = await setup((request) =>
    request.action === "options"
      ? data
      : request.action === "submit"
        ? new Promise((resolve) => (release = resolve))
        : [],
  );
  try {
    await fill(page);
    await choose(page, "custom_customer_category", "B2B");
    await page.locator("#custom_address").fill("Chennai");
    await page.locator("#submit").click();
    await page.waitForFunction(
      () => document.getElementById("submit").disabled,
    );
    await page.evaluate(() =>
      document
        .getElementById("lead-form")
        .dispatchEvent(new Event("submit", { cancelable: true })),
    );
    assert.equal(calls.filter((x) => x.action === "submit").length, 1);
    assert.deepEqual(calls.find((x) => x.action === "submit").args, {
      first_name: "Customer One",
      mobile_no: "9876543210",
      whatsapp_no: "9876543210",
      csrf_token: "test-csrf",
      custom_product_enquired: "Doors",
      source: "Website",
      custom_customer_category: "B2B",
      custom_citytown: "Chennai",
      custom_district: "Chennai - TN",
      custom_address: "Chennai",
      custom_requirement: "Residential project",
    });
    release(true);
    await page.waitForFunction(
      () => !document.getElementById("submit").disabled,
    );
    for (const id of [
      "first_name",
      "mobile_no",
      "whatsapp_no",
      "custom_requirement",
      "custom_address",
      "custom_citytown",
      "custom_district",
    ])
      assert.equal(await page.locator("#" + id).inputValue(), "");
    assert.equal(await page.locator("#source").inputValue(), "Website");
    assert.equal(
      await page.locator("#custom_customer_category").inputValue(),
      "B2B",
    );
    assert.equal(await page.locator("#same-phone").isChecked(), true);
  } finally {
    release?.(true);
    await page.close();
  }
});
test("failed submission retains typed values and renders ERP errors as text", async () => {
  const { page, calls } = await setup((request) => {
    if (request.action === "options") return data;
    if (request.action === "submit")
      throw Error("<b>ERP rejected the Lead</b>");
    return [];
  });
  try {
    await fill(page);
    await page.locator("#submit").click();
    await page.waitForFunction(
      () => !document.getElementById("form-error").hidden,
    );
    assert.equal(
      await page.locator("#first_name").inputValue(),
      "Customer One",
    );
    assert.equal(
      await page.locator("#form-error").textContent(),
      "ERP rejected the Lead",
    );
    assert.equal(await page.locator("#form-error b").count(), 0);
    assert.equal(calls.filter((x) => x.action === "submit").length, 1);
  } finally {
    await page.close();
  }
});
test("load failures can retry without opening any remote page", async () => {
  let fail = true;
  const { page } = await setup((request) => {
    if (fail) throw Error("Offline");
    return data;
  });
  try {
    assert.equal(await page.locator("#load-error").isVisible(), true);
    fail = false;
    await page.locator("#retry").click();
    await page.locator("#lead-form").waitFor({ state: "visible" });
  } finally {
    await page.close();
  }
});
test("API policy controls defaults, required fields, read only, hidden fields and option lists", async () => {
  const options = structuredClone(data);
  options.business_policy = {
    fields: {
      first_name: {
        default: "Fixed customer",
        read_only: true,
        required: true,
        max_length: 40,
      },
      custom_address: { visible: false },
      whatsapp_no: { required: false },
      source: { options: ["Referral"], default: "Referral", read_only: true },
      custom_customer_category: { required: true, options: ["B2C"] },
    },
    rules: {},
  };
  const { page } = await setup(null, options);
  try {
    assert.equal(
      await page.locator("#first_name").inputValue(),
      "Fixed customer",
    );
    assert.equal(
      await page.locator("#first_name").getAttribute("readonly"),
      "",
    );
    assert.equal(
      await page.locator("#first_name").getAttribute("maxlength"),
      "40",
    );
    assert.equal(
      await page.locator("#field-custom_address").isVisible(),
      false,
    );
    assert.equal(await page.locator("#source").inputValue(), "Referral");
    assert.equal(
      await page.locator("#field-whatsapp_no label").textContent(),
      "WhatsApp Number",
    );
    assert.equal(
      await page.locator("#field-custom_customer_category label").textContent(),
      "Customer Category *",
    );
  } finally {
    await page.close();
  }
});
test("GPS uses native address helper and failures allow retry", async () => {
  let fail = true;
  const { page, nativeMessages } = await setup(
    (request) => {
      if (request.action === "options") return data;
      if (request.action === "location") {
        if (fail) throw Error("Location permission is required.");
        return "Chennai GPS address";
      }
      return [];
    },
    data,
    360,
    true,
  );
  try {
    await page.locator("#get-location").click();
    await page.locator("#location-error").waitFor({ state: "visible" });
    assert.match(
      await page.locator("#location-error").textContent(),
      /permission/,
    );
    fail = false;
    await page.locator("#get-location").click();
    await page.waitForFunction(
      () =>
        document.getElementById("custom_address").value ===
        "Chennai GPS address",
    );
    assert.equal(
      nativeMessages.filter((x) => x.action === "location").length,
      2,
    );
  } finally {
    await page.close();
  }
});
test("Link searches debounce, ignore stale results and require a real selection", async () => {
  const options = structuredClone(data);
  options.location_fields.custom_citytown = { fieldtype: "Link", options: [] };
  let oldResolve;
  const { page, calls } = await setup((request) =>
    request.action === "options"
      ? options
      : request.args.query === "Old"
        ? new Promise((resolve) => (oldResolve = resolve))
        : ["Chennai"],
  );
  try {
    await page.locator("#custom_citytown").fill("Old");
    await page.waitForTimeout(350);
    await page.locator("#custom_citytown").fill("Che");
    await page.getByRole("option", { name: "Chennai", exact: true }).waitFor();
    oldResolve(["Old City"]);
    await page.waitForTimeout(30);
    assert.equal(
      await page.getByRole("option", { name: "Old City" }).count(),
      0,
    );
    await page.getByRole("option", { name: "Chennai", exact: true }).click();
    assert.equal(
      await page.locator("#custom_citytown").inputValue(),
      "Chennai",
    );
    assert.equal(
      calls.filter((x) => x.action === "search" && x.args.query === "Che")
        .length,
      1,
    );
  } finally {
    oldResolve?.([]);
    await page.close();
  }
});

test("hosted browser page starts itself without any app bridge", async () => {
  const { page, calls, requests } = await setup();
  try {
    assert.equal(await page.locator("#lead-form").isVisible(), true);
    assert.equal(
      await page.evaluate(() => typeof window.GenieLead),
      "undefined",
    );
    assert.equal(calls.filter((x) => x.action === "options").length, 1);
    assert.equal(await page.locator(".lc-header").isVisible(), true);
    for (const request of requests)
      assert.equal(new URL(request.url).origin, "https://erp.example.test");
  } finally {
    await page.close();
  }
});
test("app page waits for bound identity and rejects a different browser cookie user", async () => {
  const { page, calls, nativeMessages } = await setup(
    null,
    data,
    360,
    true,
    "other@example.test",
  );
  try {
    assert.equal(calls.length, 0);
    assert.equal(await page.locator("#lead-form").isVisible(), false);
    assert.match(
      await page.locator("#load-message").textContent(),
      /session|account/i,
    );
    assert.ok(nativeMessages.some((x) => x.action === "session_expired"));
  } finally {
    await page.close();
  }
});
test("Guest session and owner mismatch show an error instead of spinning", async () => {
  for (const mode of ["guest", "owner"]) {
    const options = {
      ...data,
      lead_owner: mode === "owner" ? "other@example.test" : data.lead_owner,
    };
    const { page } = await setup(
      null,
      options,
      360,
      false,
      mode === "guest" ? "Guest" : "sales@example.test",
    );
    try {
      assert.equal(await page.locator("#lead-form").isVisible(), false);
      assert.equal(await page.locator("#loading").isVisible(), false);
      assert.equal(await page.locator("#load-error").isVisible(), true);
    } finally {
      await page.close();
    }
  }
});
test("account changes before save prevent any POST", async () => {
  const env = await setup();
  try {
    await fill(env.page);
    env.setUser("other@example.test");
    await env.page.locator("#submit").click();
    await env.page.waitForFunction(
      () => !document.getElementById("load-error").hidden,
    );
    assert.equal(env.calls.filter((x) => x.action === "submit").length, 0);
  } finally {
    await env.page.close();
  }
});
test("explicit CSRF rejection refreshes once and sends existing API payload", async () => {
  let posts = 0;
  const { page, calls, requests } = await setup((request) => {
    if (request.action === "options") return data;
    if (request.action === "submit" && ++posts === 1)
      return { $http: true, status: 400, data: { exc_type: "CSRFTokenError" } };
    return true;
  });
  try {
    await fill(page);
    await page.locator("#submit").click();
    await page.locator("#lc-success").waitFor({ state: "visible" });
    assert.equal(posts, 2);
    assert.equal(
      calls.filter((x) => x.action === "submit")[1].args.csrf_token,
      "fresh-token",
    );
    assert.equal(
      requests.filter((x) => new URL(x.url).pathname === "/app").length,
      1,
    );
    const post = requests.find((x) => x.method === "POST");
    assert.equal(post.headers["x-frappe-csrf-token"], "test-csrf");
  } finally {
    await page.close();
  }
});
test("ambiguous network failure never retries a save or clears entered values", async () => {
  const { page, calls } = await setup((request) =>
    request.action === "options" ? data : { $abort: true },
  );
  try {
    await fill(page);
    await page.locator("#submit").click();
    await page.waitForFunction(
      () => !document.getElementById("form-error").hidden,
    );
    assert.match(
      await page.locator("#form-error").textContent(),
      /Check My Leads/,
    );
    assert.equal(calls.filter((x) => x.action === "submit").length, 1);
    assert.equal(await page.locator("#submit").isDisabled(), true);
    assert.equal(
      await page.locator("#first_name").inputValue(),
      "Customer One",
    );
  } finally {
    await page.close();
  }
});
