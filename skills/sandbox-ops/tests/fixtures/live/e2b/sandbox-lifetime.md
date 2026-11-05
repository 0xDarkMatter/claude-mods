<!-- Recorded excerpt of https://docs.e2b.dev/faq/sandbox-lifetime.md, fetched 2026-11-05. Test input for check-sandbox-facts.py --live --fixtures; lines are verbatim, the rest of the page is cut. -->
# How long does a sandbox live?
Every sandbox has a timeout, and it defaults to **5 minutes** if you do not set one. Pass `timeoutMs` (JavaScript, milliseconds) or `timeout` (Python, seconds) to `Sandbox.create()` to change it, or call `setTimeout()` / `set_timeout()` on a running sandbox to reset the clock from that moment.
* `onTimeout: 'kill'` (the default) terminates the sandbox and releases its resources. A killed sandbox cannot be resumed, and its state is gone.
Paused sandboxes have **no time-to-live**. There is no automatic deletion, no archiving, and no expiry after a fixed number of days. E2B never kills a paused sandbox on its own.
