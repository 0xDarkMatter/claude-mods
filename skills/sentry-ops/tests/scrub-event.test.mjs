// Tests for assets/scrub-event.mjs, named for the leak each one prevents.
// Run: node --test skills/sentry-ops/tests/scrub-event.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { STRICT_DATA_COLLECTION, makeBeforeSend, scrubEvent } from "../assets/scrub-event.mjs";

const leakyEvent = () => ({
  event_id: "abc",
  message: "contact person@example.com now",
  user: { ip_address: "203.0.113.9", email: "person@example.com" },
  breadcrumbs: [{ message: "person@example.com" }],
  extra: { note: "person@example.com" },
  request: {
    method: "POST",
    url: "https://app.test/contact/thanks?email=person%40example.com#frag",
    cookies: { session: "secret" },
    headers: { "x-custom": "value" },
    data: '{"message":"body"}',
    query_string: "email=person%40example.com",
    env: { REMOTE_ADDR: "203.0.113.9" },
  },
  exception: {
    values: [{
      type: "TypeError",
      value: "bad value for person@example.com at https://api.test/x?token=abc",
      stacktrace: { frames: [{ filename: "a.js", lineno: 3, vars: { email: "person@example.com" },
                               context_line: "const a = 1;", pre_context: ["x"], post_context: ["y"] }] },
    }],
  },
});

test("email_in_exception_message_does_not_survive", () => {
  const out = JSON.stringify(scrubEvent(leakyEvent()));
  assert.ok(!out.includes("person@example.com"), out);
});

test("urlencoded_email_in_request_url_does_not_survive", () => {
  const out = JSON.stringify(scrubEvent(leakyEvent()));
  assert.ok(!out.includes("person%40example.com"), out);
});

test("request_cookies_headers_body_and_env_are_removed", () => {
  const { request } = scrubEvent(leakyEvent());
  for (const field of ["cookies", "headers", "data", "query_string", "env"]) {
    assert.equal(request[field], undefined, field);
  }
});

test("user_breadcrumbs_and_extra_are_removed", () => {
  const out = scrubEvent(leakyEvent());
  for (const field of ["user", "breadcrumbs", "extra"]) assert.equal(out[field], undefined, field);
});

test("query_string_quoted_inside_a_message_is_cut", () => {
  const { exception } = scrubEvent(leakyEvent());
  assert.ok(!exception.values[0].value.includes("token=abc"), exception.values[0].value);
});

test("frame_vars_are_removed", () => {
  const { exception } = scrubEvent(leakyEvent());
  assert.equal(exception.values[0].stacktrace.frames[0].vars, undefined);
});

test("logentry_message_and_params_do_not_leak", () => {
  const event = { logentry: { message: "hi person@example.com", params: ["person@example.com"] } };
  const out = JSON.stringify(scrubEvent(event));
  assert.ok(!out.includes("person@example.com"), out);
});

test("sensitive_route_keeps_only_type_and_path", () => {
  const out = scrubEvent(leakyEvent(), { isSensitivePath: (p) => p.startsWith("/contact") });
  const exc = out.exception.values[0];
  assert.equal(exc.type, "TypeError");
  assert.equal(out.request.url, "https://app.test/contact/thanks");
  assert.ok(!exc.value.includes("bad value"), exc.value);
  assert.ok(!out.message.includes("contact person"), out.message);
  assert.equal(exc.stacktrace.frames[0].context_line, undefined);
});

test("relative_request_url_still_matches_a_sensitive_route", () => {
  const event = { request: { url: "/admin/users?x=1" }, exception: { values: [{ type: "E", value: "secret text" }] } };
  const out = scrubEvent(event, { isSensitivePath: (p) => p.startsWith("/admin") });
  assert.ok(!out.exception.values[0].value.includes("secret text"));
});

test("debug_context_survives_scrubbing", () => {
  const exc = scrubEvent(leakyEvent()).exception.values[0];
  assert.equal(exc.type, "TypeError");
  assert.equal(exc.stacktrace.frames[0].filename, "a.js");
  assert.equal(exc.stacktrace.frames[0].lineno, 3);
  assert.ok(exc.value.startsWith("bad value for"));
});

test("scrubber_failure_drops_the_event_instead_of_sending_it", () => {
  const beforeSend = makeBeforeSend({ isSensitivePath: () => { throw new Error("broken rule"); } });
  assert.equal(beforeSend(leakyEvent()), null);
});

test("event_without_optional_fields_does_not_throw", () => {
  assert.deepEqual(scrubEvent({ event_id: "x" }), { event_id: "x" });
});

test("hostile_long_message_does_not_hang_the_scrubber", () => {
  const started = Date.now();
  scrubEvent({ message: `${"a".repeat(200000)}@`, exception: { values: [{ value: "a.".repeat(100000) }] } });
  assert.ok(Date.now() - started < 2000, "regex backtracking");
});

test("strict_baseline_turns_every_category_off", () => {
  for (const [key, value] of Object.entries(STRICT_DATA_COLLECTION)) {
    const off = value === false || value === 0 || (Array.isArray(value) && value.length === 0)
      || (typeof value === "object" && Object.values(value).every((v) => v === false));
    assert.ok(off, `${key} is not off`);
  }
});
