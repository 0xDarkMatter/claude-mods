---
name: ca-trust-ops
description: "Check whether a machine still trusts a compromised or distrusted certificate authority (a CA distrust event): a read-only checker for macOS, Linux, WSL and Windows that probes curl, git, Python, Node and the Windows certificate store against the incident's test hosts, matches CA bundles (system, Homebrew, certifi, pip, Node, Git for Windows, Composer, WSL, a Docker image's) by public key, and flags tools older than the fix. A failed connection never counts as safe. Ships incident packs (eMudhra, October 2026) and the procedure to add one. Use when asked whether a machine is patched against a CA compromise, to confirm a fix, OS update or new toolchain, to check an extracted CA bundle, or to add a new CA incident."
license: MIT
allowed-tools: "Read Bash Grep Glob"
metadata:
  author: claude-mods
  related-skills: "security-ops, supply-chain-defense, net-ops, windows-ops, mac-ops"
---

# CA trust checks against a distrust event

When a certificate authority is compromised or distrusted, browsers block it within days,
but command-line tools and language runtimes that carry their own CA list (curl, git,
Python's certifi, Node, Composer, uv, Bun, Deno, Claude Code) can keep trusting it for
months. This skill runs one read-only checker that reports, per client and per CA bundle,
whether this machine still trusts a chain built on the incident's listed keys. It changes
nothing, needs no admin rights and writes only to stdout.

The checker is generic; everything about one incident lives in an **incident pack**,
`assets/incidents/<id>.conf`:

| Pack | Incident | Facts as of | Reference |
| --- | --- | --- | --- |
| `emudhra-2026-10` | eMudhra CA compromise, October 2026 (12 keys, 2 trust paths) | 2026-10-26 | `references/emudhra-2026-10.md` |

## Steps

1. **Pick the pack.** Match the incident the user names to the table above, or list what
   this copy carries:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/scripts/check-ca-trust.sh" --list
   ```

   No pack for the incident? Say so and offer to add one (step 6); never point the checker
   at hosts of your own.

2. **Run the checker for this machine**, from any folder.

   macOS, Linux, or inside WSL:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/scripts/check-ca-trust.sh" --incident emudhra-2026-10
   ```

   Windows, from PowerShell 5.1 or 7:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/check-ca-trust.ps1" -Incident emudhra-2026-10
   ```

   It takes a few seconds to a minute. Add `--scan DIR` (`-Scan DIR`) for project virtual
   environments outside the usual places, `--offline` (`-Offline`) to skip the network, or
   `--bundle FILE` (`-Bundle FILE`) to check only a bundle, such as one extracted from a
   Docker image (`docker cp <container>:/etc/ssl/certs/ca-certificates.crt .`).

3. **Read the exit code and the lines.**

   | Exit | Meaning |
   | --- | --- |
   | 0 | Every line PASS |
   | 10 | At least one FAIL: that client or bundle still trusts a listed key |
   | 11 | No FAIL, but at least one UNKNOWN: something could not be tested |
   | 2 | Usage error (unknown option, no `--incident`, a malformed test hook) |
   | 3 | No incident pack by that name |
   | 4 | The incident pack is malformed (the message names the line) |

   Each line is `STATUS id detail`, and a FAIL or UNKNOWN line ends with `- fix:` and one
   command or step. A network test is PASS only when three things hold: the client opened
   the pack's control page; the checker's own TLS handshake with each test host saw a
   listed key in the chain, on a current certificate that names the host; and the client
   then refused every test chain with a certificate error. Anything else is UNKNOWN, never
   PASS: a blocked or intercepted test host, a reset or an expired certificate all look
   like a refusal from the client's side. The last line, `RESULT ...`, holds no host, user
   or path and is the line to share.

4. **Report, then propose fixes; never apply them unasked.** Show the FAIL and UNKNOWN
   lines with their fixes. A fix that needs `sudo` or admin rights, edits a shell profile,
   or changes a system trust store is the user's to run: show the command and wait. Never
   get past a certificate error by turning verification off (`-k`, `verify=False`,
   `NODE_TLS_REJECT_UNAUTHORIZED=0`): that trusts every certificate, not one fewer. Read
   the pack's reference for what the operating system does on its own and for
   incident-specific workarounds (for eMudhra: macOS `/etc/ssl/cert.pem`, and why Python
   can FAIL on a patched Windows).

5. **Re-run after each fix** and report the new `RESULT` line.

6. **Adding an incident** (a new compromise or distrust): follow
   `references/incident-packs.md`. Every key is verified from two independent sources,
   printed into the pack by `scripts/pack-keys.sh`, and backed by real certificates in
   `tests/fixtures/<id>/`; `bash "${CLAUDE_SKILL_DIR}/tests/run.sh"` fails until the pack,
   its fixtures and its reference agree.

## What it reads and sends

- Reads: CA bundle files, `git config`, the `--version` of the tools the pack names, and
  the environment variables `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`,
  `PIP_CERT`, `NODE_EXTRA_CA_CERTS`, `GIT_SSL_CAINFO`, `NODE_TLS_REJECT_UNAUTHORIZED`,
  `PYTHONHTTPSVERIFY` and `GIT_SSL_NO_VERIFY`. Paths under the home folder print as `~`.
- Sends: a GET to the pack's control host and each path host from each client tested, with
  the User-Agent `ca-trust-ops/1`, and one TLS handshake with each path host to confirm its
  chain (`openssl s_client`, or .NET on Windows). No client follows a redirect or uses a
  proxy, so every request takes the same route as that handshake; on a network that allows
  HTTPS only through a proxy, the results are UNKNOWN. curl runs with `-q`, so `.curlrc` is
  ignored; git runs with no credential helper, no extra headers and no cookie file.
  `SSLKEYLOGFILE` and git's trace variables are cleared for the run. Disclosure sites
  typically count connections per User-Agent and nothing else.
- On Windows, the system's own certificate checks (.NET, Schannel `curl.exe`, git's Schannel
  backend) may also fetch revocation lists and Microsoft's root and distrust updates, as
  they do for any HTTPS connection.
- Never: runs `sudo`, writes a file, pipes anything into a shell, or sends a request to a
  host the pack does not name.

## Limits

It does not look inside Docker images or DDEV containers (extract the bundle and use
`--bundle`), Java `cacerts`, Go binaries or Electron apps. It does not test the operating
systems' own trust stores (macOS Keychain, the Windows store for apps other than the ones
named), so keep the OS updated. Tools the pack lists under `version` are judged by version,
not by their bundled roots. PHP and Composer are checked on Windows only, and on Windows
only the `git`, `python`, `node`, `php` and `composer` on the `PATH` and the default WSL
distribution; inside WSL, run the bash checker too. Related skills: `security-ops` for a
codebase audit, `supply-chain-defense` for dependency risk, `net-ops` when the test hosts
cannot be reached at all, `windows-ops` and `mac-ops` for the machine itself.

Changing the checkers: read `AGENTS.md` in this folder first; its landmines are the reasons
for the code's odd-looking choices.
