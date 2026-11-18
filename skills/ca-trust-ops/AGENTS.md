# `skills/ca-trust-ops/`

Adds to the root AGENTS.md for this skill: a read-only checker that a user runs on their own
machine, plus incident packs. This file is about changing it. Gate: `bash
skills/ca-trust-ops/tests/run.sh` (also run by `just check`); its `--group` flag runs one part.

## Map

| Path | What |
| --- | --- |
| `scripts/check-ca-trust.sh` | macOS, Linux, WSL checker (bash 3.2) |
| `scripts/check-ca-trust.ps1` | Windows checker (PowerShell 5.1 and pwsh 7) |
| `scripts/pack-keys.sh` | prints a pack's `key` lines from certificates |
| `assets/incidents/<id>.conf` | incident packs: keys, hosts, fixed versions |
| `references/incident-packs.md` | the pack format, field rules, how to add one |
| `references/<id>.md` | one incident's sources, verification, platform notes |
| `tests/fixtures/<id>/` | the real certificates behind each pack's keys |

## Landmines

- **Never write a file, run `sudo`, pipe into a shell, follow a redirect, use a proxy, or
  contact a host the pack does not name.** That is why the bash checker has no
  here-documents or here-strings (bash before 5.1 backs both with temporary files) and
  clears `SSLKEYLOGFILE`, git's trace variables and every proxy variable. Every probe goes
  direct, the same route as the handshake check: a probe that went through a proxy could
  see the proxy's block page, and its refusal would read as PASS.
- **A network result counts only when three things hold**, and the suite's
  `client_that_trusts_nothing_*`, `test_site_*`, `a_reset_*` and `a_filtering_proxy_*`
  cases fail when any is dropped:
  - the same client opened the control page (a client with an empty or unreadable bundle
    rejects everything);
  - the checker's own handshake with each path host saw a listed key, on a current leaf
    whose DNS names include the host as a whole name (`path_state`, `Get-PathState`;
    `host.example.invalid` is not `host`);
  - the client's error was a certificate error: an untrusted issuer for Python
    (`verify_code`), Node (its error code) and git; curl's exit 60, or 35 only with a
    revocation or untrusted-root message; on Windows, a .NET certificate error. curl and
    .NET cannot say why they refused, so for them the handshake check carries the name and
    date checks.
- **Packs are untrusted input.** Hosts and commands from a pack reach the network and the
  PATH, so both loaders validate every field and refuse unknown record types (exit 4), and
  they must agree: a pack one accepts, the other must accept. Change `load_pack` and
  `Read-Pack` together; the suite's `bad-*` packs pin the rules. `--incident` takes a name,
  never a path.
- **Keys live only in packs** (the suite fails on a 64-hex string in `scripts/`). A pack's
  keys must equal its fixtures' keys, each `key` line's SPKI must hash to its key, and
  `pack-keys.sh` must reproduce the lines: change the pack and the fixtures in one commit.
- **The bash bundle scan is a prefilter, then a hash.** `SCAN_AWK` looks for each listed
  key's public-key bytes in each certificate's base64 at all three byte alignments; only a
  match is hashed with openssl (`confirm_candidate`). Hashing every certificate cost three
  openssl start-ups each, 5 s per 120-certificate bundle. Do not drop an alignment or the
  confirmation: `every_listed_fixture_certificate_is_caught` and
  `an_unreadable_certificate_holding_a_listed_key_is_unknown` catch both.
- **`CA_TRUST_LOCAL_PORTS=<control>,<one port per path>`** points the bash checker at
  `localhost` for the suite's real-client tests (ports 8191 to 8194, the throwaway range).
  Digits and commas only, the port count must match the paths, and it always means
  localhost, so it cannot send the checker anywhere else. Keep it that way.
- **Exit codes follow the repo's resource protocol**: 0 all PASS, 10 any FAIL, 11 UNKNOWN
  only, 2 usage, 3 no such pack, 4 malformed pack. (The checker this skill grew from used
  1, 2 and 64.)
- **The RESULT line is pasted into threads to sign a machine off.** No host, user name or
  path, and its fields stay in order: the suite's `RESULT_RE` pins the format.
- **macOS:** `/usr/bin/git` and `/usr/bin/python3` are shims that open the Command Line
  Tools installer when the tools are missing; the checker checks `xcode-select -p` before
  calling either. The bash checker runs under bash 3.2: no associative arrays or `mapfile`;
  an empty `"$@"` or `"${a[@]}"` under `set -u` aborts, so arguments pass as `${1+"$@"}`
  and arrays are walked by index; no `timeout` command (`with_timeout` stands in); awk is
  POSIX awk (no `gensub`, no bit operations).
- **PowerShell:** the file stays ASCII (5.1 reads it in the ANSI code page). 5.1 mangles
  double quotes inside arguments to native programs, so the Python, Node and PHP snippets
  use single quotes. `pwsh -File` passes `-Bundle a,b` as one string, which the script
  splits. Change environment variables only through `Set-ProcessEnv`: under pwsh 7,
  `[Environment]::SetEnvironmentVariable($n, $null)` leaves an empty variable (PowerShell
  binds `$null` to a string parameter as `''`), and git turns curl tracing on when
  `GIT_CURL_VERBOSE` merely exists. Windows variable names ignore case, and so does a
  hashtable: save every variable before clearing any, in a case-sensitive dictionary. A
  pack hashtable entry named `Keys`, `Values` or `Count` is shadowed by the hashtable's own
  property (hence `Listed`). Under StrictMode 2, `.Count` on a scalar throws: wrap in `@()`.
  The TLS callback in `Get-PathState` is a scriptblock, which works only because
  `AuthenticateAsClient` is synchronous. Read SAN names from the extension's DER
  (`Get-DnsNames`): `Format()` is localized.
- **Where the tests run.** The stand-in and real-client groups run on Linux only (the bash
  checker refuses Git Bash); on Windows the suite runs the pack, bundle and PowerShell groups
  and their mutants. Two PowerShell mutants need a host quirk (pwsh 7's empty variable,
  case-insensitive names) and are skipped where the quirk is absent. Real-client cases need
  `python3` and `openssl s_server`, and test `node` when it is installed. Their test
  certificates must pass strict verification (`new_ca` spells out keyUsage, AKI/SKI and
  basicConstraints): Python 3.13+ verifies with `VERIFY_X509_STRICT`, so a CA without
  keyUsage made every `real_python3` case read UNKNOWN on Linux CI only, while curl, git and
  node passed. `local_test_chains_pass_x509_strict` checks this first. Under Git Bash,
  pass a `/mnt/...` path to `wsl.exe` with `MSYS_NO_PATHCONV=1`.
- **On Windows, `python` can read FAIL while `windows-store` reads PASS.** That is real:
  Python's `urllib` loads the Windows root store into OpenSSL, which ignores Microsoft's
  distrust lists.
- **Fixtures are `.crt`, never `.pem`**: push gates commonly refuse `*.pem` paths as key
  material. They still contain `-----BEGIN CERTIFICATE-----` lines, which secret scanners
  may flag; they are public certificates.
