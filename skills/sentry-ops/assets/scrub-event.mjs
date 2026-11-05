// Strict `beforeSend` scrubber for the Sentry JavaScript SDKs. Copy into the app.
//
// Contract: pure and synchronous, with no SDK import, so it runs and is tested
// without Sentry. It keeps what you need to debug (error type, stack, route path)
// and removes what identifies a person. It never throws: an exception inside
// `beforeSend` must not cost you the error report, so on failure it drops the event
// rather than sending it unscrubbed.
//
// It is a second layer behind `dataCollection` (see references/privacy-baseline.md).
// `beforeSend` sees error and message events only: spans, logs and metrics have
// their own hooks, which is one reason the baseline leaves those products off.
//
// Domain: the event shape is Sentry's event payload,
// https://develop.sentry.dev/sdk/data-model/event-payloads/

// Bounded quantifiers keep this linear on hostile input: exception messages can
// quote attacker-controlled strings. RFC 5321 caps a local part at 64 and a domain
// at 255.
const EMAIL = /[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){1,8}/g;
// Query strings quoted inside messages, such as a fetch error that names its URL.
const URL_QUERY = /(https?:\/\/[^\s?#"'<>]{1,2048})[?#][^\s"'<>]*/g;

// Every category off. Pass as the `dataCollection` option on each SDK init.
//
// Guard: v11 collects everything unless told otherwise, and a category added by a
// future SDK defaults to ON, so this list can go stale without anything breaking.
// `check-sentry-facts.py --live` compares these keys with the SDK's own defaults.
// `sendDefaultPii` was removed in v11: adding it here would do nothing.
export const STRICT_DATA_COLLECTION = Object.freeze({
  userInfo: false,
  cookies: false,
  httpHeaders: false,
  httpBodies: [],
  urlQueryParams: false,
  graphQL: { document: false, variables: false },
  genAI: { inputs: false, outputs: false },
  mcp: { inputs: false, outputs: false },
  databaseQueryData: false,
  queues: false,
  stackFrameVariables: false,
  frameContextLines: 0,
});

const REDACTED_EMAIL = "[email]";
const REDACTED_MESSAGE = "[message removed on sensitive route]";

function redact(text) {
  if (typeof text !== "string") return text;
  return text.replace(EMAIL, REDACTED_EMAIL).replace(URL_QUERY, "$1");
}

function pathOf(url) {
  if (typeof url !== "string") return undefined;
  const stop = url.search(/[?#]/);
  return stop === -1 ? url : url.slice(0, stop);
}

function requestPath(url) {
  const bare = pathOf(url);
  if (bare === undefined) return "";
  try {
    return new URL(bare, "http://relative.invalid").pathname;
  } catch {
    return bare;
  }
}

/**
 * @param {object} event Sentry event; mutated and returned.
 * @param {object} [options]
 * @param {(path: string) => boolean} [options.isSensitivePath] Routes where people
 *   type personal data (forms, admin). Their events keep only the error type and path.
 * @returns {object} the scrubbed event
 */
export function scrubEvent(event, { isSensitivePath = () => false } = {}) {
  delete event.user;
  delete event.breadcrumbs;
  delete event.extra;

  const request = event.request;
  const path = requestPath(request && request.url);
  if (request) {
    delete request.cookies;
    delete request.headers;
    delete request.data;
    delete request.query_string;
    delete request.env;
    if (request.url !== undefined) request.url = pathOf(request.url);
  }
  const sensitive = isSensitivePath(path);

  if (typeof event.transaction === "string") event.transaction = redact(event.transaction);
  if (event.message !== undefined) {
    event.message = sensitive ? REDACTED_MESSAGE : redact(event.message);
  }
  if (event.logentry) {
    delete event.logentry.params;
    event.logentry.message = sensitive ? REDACTED_MESSAGE : redact(event.logentry.message);
    if (event.logentry.formatted !== undefined) {
      event.logentry.formatted = sensitive ? REDACTED_MESSAGE : redact(event.logentry.formatted);
    }
  }

  for (const exception of (event.exception && event.exception.values) || []) {
    exception.value = sensitive ? REDACTED_MESSAGE : redact(exception.value);
    for (const frame of (exception.stacktrace && exception.stacktrace.frames) || []) {
      delete frame.vars;
      // Source lines can quote a form's labels or a hard-coded address.
      if (sensitive) {
        delete frame.context_line;
        delete frame.pre_context;
        delete frame.post_context;
      }
    }
  }
  return event;
}

/**
 * Build the `beforeSend` option. Returning null drops the event, which is the safe
 * failure: an unscrubbed event must never leave because the scrubber broke.
 */
export function makeBeforeSend(options) {
  return (event) => {
    try {
      return scrubEvent(event, options);
    } catch {
      return null;
    }
  };
}
