# Changelog

All notable changes to claude-mods are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). Fuller narrative entries for
feature releases live in the README "Recent Updates" section.
## [Unreleased]

### Added

- **Agent Skills spec gate (`tests/spec.sh`)** - every skill is checked by the spec's
  own reference validator, `skills-ref` (pinned 0.1.1, run through `uv` with its whole
  dependency tree frozen past a 7-day cooldown), in `just check`, `check-fast` and CI.
  The one deliberate deviation is now written policy: Claude Code's 14 documented
  fields (`when_to_use`, `argument-hint`, `effort`, ...) stay top-level, because Claude
  Code reads them nowhere else. Anything else outside the spec's six is rejected, which
  catches typos like `when-to-use` that Claude Code ignores silently. The gate also
  checks that `metadata` values are strings (a spec rule `skills-ref` can't see) and
  lists the skills that can't be uploaded to claude.ai as-is. Skill size stays with
  `tests/skill-size.sh`. A fixture self-test runs first, so a validator that passes
  everything fails the gate.
  The frontmatter docs (`rules/naming-conventions.md`, `docs/SKILL-SUBAGENT-REFERENCE.md`,
  `docs/SKILL-CREATION-PROTOCOL.md`) now state one rule. They had contradicted each other,
  and two of them called `claude plugin validate` authoritative for skills, though it
  never reads SKILL.md.
- **`security-ops` covers PHP 8, Twig and Craft CMS** - fourteen one-topic references
  (each 300 lines or fewer, Contents-listed, cited inline to Craft, Twig, PHP manual and
  OWASP sources): Twig escaping and template injection; Craft CSRF/Formie, access control
  and `allowAnonymous`, config and security-key hardening, uploads, GraphQL, and an
  advisories reference that leads with Craft 3 and 4 being past security end of life;
  PHP input validation, SQL via the query builder versus raw SQL, deserialisation,
  password hashing, and Composer audit (behavioural supply-chain work stays in
  `supply-chain-defense`); DDEV-versus-production drift. `security-scan.sh` gains PHP,
  Twig/Craft-template and Craft-config checks and stops flagging committed
  `.env.example.*` files; `dependency-audit.sh` runs `composer audit --locked`. A
  stack-routing table in SKILL.md maps detection to references.

- **`security-ops` speaks OWASP Top 10:2025** - findings, agent prompts, the
  consolidation step and the report template now tag `Axx:2025` IDs, verified against
  top10.owasp.org/2025. The OWASP references gain an A03 Software Supply Chain Failures
  section (routing behavioural work to `supply-chain-defense` and Composer to
  `php-composer-supply-chain.md`), an A10 Mishandling of Exceptional Conditions section
  (fail-closed handlers, rollback, generic errors, unchecked PHP returns), SSRF folded
  into A01, and a review checklist of `rg` patterns each. `audit-quickref.md` carries a
  2021-to-2025 crosswalk so older reports stay readable. Filenames are unchanged - they
  name ID ranges, which 2025 kept.

- **`deploy-gating` rule** - a child session never deploys. Background agents, chips,
  workflow/fleet workers, headless and scheduled runs, and CI-autofix or review-triage
  loops may build, test and commit, but stop at the deploy boundary and report the
  exact command and its effect. The deploy list is explicit about the case agents
  miss: **merging or pushing to a branch that deploys automatically** (deploy-on-merge
  CI, CodeDeploy `appspec.yml`, git-integrated hosting) *is* a deploy even though no
  deploy command is typed. Only a live instruction in the user's own session
  authorises one; an instruction written into a chip or lane brief does not.

- **`adr-touching.py` batched queries** - several positionals in one call:
  the ADR set is parsed once and every query is matched against it, so a
  caller with N paths pays one spawn instead of N. `--json` gains a
  `queries` list with a per-query `{query, governing, rc}` verdict; `data`
  is the deduped union so `.data[].number` keeps working, and a single-query
  call's envelope and text rows are byte-identical to before. Exit stays
  `10`/`0`, now any-governed across the batch; a blank query anywhere is
  usage (`2`) for the whole call rather than a silent skip. Motivated by
  fleetflow's plan lint spending 33s of a 40s run spawning it 225 times.

- **`push-gate` regex-layer allowlist (`.pushgate-allow`)** - the regex secret
  layer gains the repo-local allowlist the gitleaks layer always had via
  `.gitleaksignore`. A committed repo-root file, one `<path>:<line-regex>`
  entry per line with a required reason comment above each; entries anchor on
  content, never line numbers (they drift), and suppress hits only in their
  exact file - everything not allowlisted still refuses, and there is still no
  inline bypass. Refusals now print a ready-made anchored entry to copy; an
  entry whose file or matching line no longer exists at the branch tip warns
  as stale. Born from a real push where nine verified test fixtures and a
  deliberately unsigned JWT forced a manual override of hard rule 2 - exactly
  what the rule exists to avoid normalising. The scanner keeps per-line file
  attribution now, and the self-test grows eight allowlist assertions.

- **`a11y-ops` server-rendered templates reference** - WCAG 2.2 for Craft CMS
  and Twig sites, where no single file owns the page. Covers heading levels
  passed into partials, landmarks owned by the layout, alt text when the asset
  carries it but the placement decides it (`getImg()` drops an empty `alt`),
  what Formie 3 and the CKEditor plugin actually render (read from source,
  including Formie's server-rendered errors arriving as a CSS class only), and
  `lang`/`hreflang` on multi-site. Testing runs axe through Playwright or
  Cypress and pa11y-ci against a DDEV URL, keeping `best-practice` in the axe
  tags because `heading-order` and the landmark rules live there. The skill
  description is trimmed to a 500-character "Use when" form, now pinned by the
  skill's own suite.

### Fixed

- **Gates went red when Claude Code reserved the plugin name** - Claude Code 2.1.287
  launched Claude Mods and reserved plugin names that pass as Anthropic's own, naming
  `claude-mods` explicitly. `claude plugin validate` now rejects it (install and load
  still work), which failed `tests/validate.sh` and CI on an untouched `main` and blocked
  every landing. `tests/plugin-validate.sh` now runs the validator and waives ONLY that
  error, as a dated WARN, until 2026-10-31. Any other validator error still fails, and the
  waiver itself fails after its expiry so the rename can't be forgotten. It self-tests
  against fixtures before judging the repo; a waive-everything mutation fails that
  self-test. `validate.sh` and the CI step both route through it. TODO(rename): rename
  the plugin, then delete the waiver.
- **`fleet-worker` doctor said "no API key" on hosts where the launcher ran fine** -
  `fleet-doctor.sh --live` carried its own if/elif copy of the key chain, so with
  `FLEET_WORKER_KEYRING_SERVICE`/`_KEY` set but an empty keyring entry it never fell
  through to `ZHIPU_API_KEY`/`GLM_API_KEY` (fleetflow surfaced it as
  `glm-endpoint unreachable (rc=7)`). Defaults and the resolver now live once in
  `scripts/fleet-lib.sh`, sourced by both; the suite fails if a second `keyring get`
  copy appears. `--live` also gains a `live-cli` probe that runs one real `claude`
  turn through the launcher, so a model the endpoint accepts but the CLI cannot run
  is reported as drift instead of passed. It judges the JSON result, not stderr:
  Claude Code 2.1.280 prints `[claude-code:unrecognized_model]` for every
  non-catalog id, healthy runs included. Default model ids move to the canonical
  lowercase `glm-5.3` / `glm-4.5-air` (both verified live; the uppercase ids also
  still work).

- **`prompt-injection-defense` left terminal controls and most default-ignorables
  unbanded** - the hidden-Unicode catalog now covers every Default_Ignorable code
  point (4174 in UCD 18.0) and every C0/C1 control except TAB, LF and CR, and the
  self-test pins both sets, so a gap fails the build instead of passing silently.
  New `high` bands: ESC (an `ESC[8m` run is concealed in a terminal `git diff`), the
  other C0 controls (BS overprints; a single NUL turns `git diff` into "Binary files
  differ"), DEL, the C1 controls (`U+009B` is an 8-bit CSI), the deprecated format
  characters `U+206A`-`U+206F`, the musical format characters and the reserved
  default-ignorable ranges; US joins the FS-RS band. New `medium` bands, stripped
  only at `aggressive`: the Mongolian free variation selectors and the Duployan
  shorthand format controls. Catalog v0.3.0 adds an optional `ranges` field for
  bands the code chart splits, and the self-test fails if two bands overlap, since
  the scanner and the sanitizer would then name different bands.

- **`supply-chain-defense` `preinstall-check.sh` never exited 7 on an unreachable
  registry** - `fetch()` set the unavailable flag inside `$(...)`, a subshell, so the
  assignment died with it and a dead registry looked like "outside cooldown" (exit 0).
  Callers now set the flag from fetch's exit status. Found by the new copy-alone test,
  which also caught `integrity-audit.sh` printing em dashes in its zizmor lines (its
  plain fallback framing is now 7-bit ASCII, as is its `TERM_ASCII=1` output).

- **The unicode hooks could pick a Python too old to run the scanner** -
  `session-start-unicode-scan.sh` and `pre-commit-unicode-scan.sh` probed candidates
  with a bare `import sys`, which a pre-3.8 interpreter passes. With one ahead on PATH
  the SessionStart hook printed an empty advisory for a clean project, and the
  pre-commit gate let a critical bidi override through. Both now take the first of
  `python3`/`python`/`py` that is really 3.8+, and their fix hints use the launcher.

- **`prompt-injection-defense` missed line separators and invisible fillers** -
  `scan-hidden-unicode.py` reported `ok<U+2028>=== FORGED ===` as clean, though a
  model may read `U+2028` as a new line that no reviewer sees. The scanner split
  lines with `str.splitlines()`, which drops VT, FF, FS-RS, NEL, `U+2028` and
  `U+2029` before they can be classified (and shifts every later line number); it
  now splits on CRLF/CR/LF only. New catalog bands: line/paragraph separators, NEL,
  FS-RS, soft hyphen, CGJ, Khmer inherent vowels and the Hangul fillers at `high`;
  VT/FF and the Mongolian vowel separator at `medium`. `sanitize-content.py` now
  flattens the line-break bands and the blank-rendering Hangul fillers to a space
  (new catalog field `replace_with`, reported as `replaced_by_band`) instead of
  deleting them, so a forged line can't survive and words never fuse.

- **Supply-chain, worktree and enforce-uv hooks never reached the model** -
  the pigeon hook's output-channel defect, in five more hooks. The
  auto-wired advisories (`pre-install-scan`, `worktree-guard` on PreToolUse,
  `manifest-dep-scan` on PostToolUse) echoed plain text, which Claude Code sends
  to the debug log for tool events; they now emit one
  `hookSpecificOutput.additionalContext` JSON envelope via `jq`.
  `pre-install-scan`'s `SUPPLY_CHAIN_BLOCK=1` gate and `enforce-uv` blocked with
  their reason on stdout, so the agent was stopped with "No stderr output"; the
  reason now goes to stderr. `config-change-guard` sent a `systemMessage`, which
  ConfigChange discards (as it does every text channel); on an IOC it now also
  raises a desktop notification via `terminalSequence`, the one field that
  event delivers (interactive sessions only). Verified A/B with headless
  `claude -p` on 2.1.280: every old hook's text was absent from the model's
  context, every fixed hook's text was quoted back. `tests/hooks.sh` pins each
  channel (8 new assertions fail against the old hooks) and the hooks README
  gains an "Output channels" table; its "output goes to Claude's context"
  best-practice line was wrong and is gone.
- **`pigeon send`, `reply` and `broadcast` no longer fail on Windows for bodies
  over ~32 KB.** The escaped body went to `sqlite3.exe` as a command-line argument,
  and Windows caps a command line at 32,767 chars, so a large message died with
  "Argument list too long" (rc 126) and nothing was stored. Linux allows ~2 MB, so
  CI never saw it. Message INSERTs now reach sqlite3 on stdin via one `sql_exec`
  helper; a 2 MB body round-trips. Stdin is read in text mode on Windows, where a
  raw Ctrl-Z (0x1A) means end-of-file, so `sql_escape` now splices that byte back
  in as `char(26)`. The pigeon suite gains four Windows regressions (40 KB send,
  reply and broadcast round-trips, plus Ctrl-Z), each seen failing first.
- **doc-drift link checks are now case-exact, and CI's doc-drift step passes
  again.** `fleet-worker` linked `docs/auto-mode-classifier.md`, but the file is
  `docs/AUTO-MODE-CLASSIFIER.md`. The gate tested links with `[ -e ]`, which is
  case-insensitive on Windows and macOS, so it passed locally and failed only on
  Linux CI - where it had kept the validate job red since mid-September and stopped
  every later step from running. Links are now checked component by component
  against the real on-disk spelling (directory listings cached, pure-bash
  comparison), so a wrong-case link fails locally too; the three wrong-case
  references are corrected.
- **windows-ops suite no longer fails on Linux CI.** It skipped its PowerShell
  checks only when `pwsh` was missing, but GitHub's Ubuntu runners ship `pwsh`, so
  the Windows-only scripts (robocopy, CIM, process ancestry) were executed there
  and returned the wrong exit codes. Six assertions failed on every run, hidden
  until the doc-drift fix let the step run at all. The script-runtime checks now
  gate on the PowerShell host reporting `Win32NT`; the static and `common.ps1`
  framing checks still run everywhere.

- **`install.ps1 -Doctor` reported phantom drift whenever the install target
  was spelled differently from how PowerShell spells it** - the reason the
  `install-guard` CI job had never passed on a Windows runner. Relative paths
  were cut as `FullName.Substring($root.Length + 1)`, but the FileSystem
  provider returns children under its own canonical form of the root (8.3
  short names expanded, `..` collapsed). A GitHub runner's `%TEMP%` is the
  short form `C:\Users\RUNNER~1`, three characters shorter than the canonical
  `runneradmin`. So an installed `skills/alpha/SKILL.md` read back as
  `skills/ls/alpha/SKILL.md`, and the doctor reported every installed skill
  file as both missing and orphaned. The installer's merge-copy had the same
  flaw: its dest-only list was garbage, or the skill failed to sync outright
  when the given spelling was longer. It passed locally only on volumes with
  8.3 names disabled. All relative paths now come from one `Get-FilesUnder`
  helper, which resolves the root through the provider and enumerates from
  that spelling. `tests/install-guard.sh` section 12 pins it on any volume
  with a `..`-spelled target; it fails against the old installer.
  `tests/check-resources.sh` adds a grep backstop for the Linux CI.

- **pigeon mail notifications never reached the model** - `check-mail.sh`
  printed its delivery block as plain stdout. For PreToolUse hooks, Claude Code
  sends plain stdout to the debug log. Only UserPromptSubmit, SessionStart and
  a few other events add it to context. The hook now emits one
  `hookSpecificOutput.additionalContext` JSON envelope via `jq`, and it
  truncates message bodies to stay under the 10,000-char cap. Verified with
  headless `claude -p` on 2.1.280: the old hook fired, but the model answered
  NONE in 2 of 2 runs. With the new hook, the model quoted the planted code
  word in 2 of 2 runs. The hook now needs `jq` and stays silent without it.

- **pigeon attachments reported `(missing)` on Windows** - every attachment but
  the last. Windows' native `sqlite3.exe` writes `\r\n` in text mode, and
  command substitution strips only the final newline, so each line-parsed path
  kept a stray `\r` and failed its existence check although the stored path
  was clean. `mail-db.sh` now routes every query through one `sqlite3`
  function that strips CR (exit status kept via `pipefail`), fixing the
  attachment loops and the other line-by-line readers at once. The
  `check-mail.sh` delivery hook has its own attachment loop and had the same
  bug, and multi-line bodies reached the model with stray CRs. It now uses the
  same CR-stripping `sqlite3` function.

- **The agnostic gate now actually runs - and can no longer pass while blind.**
  `tests/agnostic.sh` existed but was wired into neither `just check` nor CI, so
  author-specific paths and names crept back into a public repo. It now runs in
  `just check`, `just check-fast` and the validate workflow. Hardening, each for a
  failure it had: rg errors (exit 2) fail the gate instead of reading as "no
  matches"; `rg --path-separator /` is gone (Git Bash rewrote the `/` to its install
  dir, so every scan errored silently and reported PASS); `--no-ignore-parent` stops
  a run from a lane worktree scanning nothing; a run that sees 0 files fails; and
  there is no PCRE2 dependency. The committed script now carries only generic
  patterns (user-profile paths with a real-looking name, placeholders allowed) -
  author-specific identifiers moved to a private, never-committed deny list
  (`~/.claude/agnostic-deny.txt` or gitignored `tests/agnostic-deny.local`), because
  a public gate that lists what it protects publishes it. Line-level exceptions go
  in `tests/agnostic-allow.txt` with a reason. Nine leaked identifiers were replaced
  with placeholders across r-ops, windows-ops, portless-ops, svg-brand-tint-ops,
  `tests/validate.sh` and an archived brief; `rules/dev-servers.md` is now a
  generic template (the concrete stack values belong in a private `CLAUDE.md`).

- **The opt-in quality hooks now work under Claude Code's real hook contract** - input
  as JSON on stdin, exit 2 + stderr to block. None had been tested against it, and
  all three were broken: `post-edit-format` read only `$1`, so it silently formatted
  nothing; `pre-commit-lint` exited 1 - a non-blocking error - so the commit went
  ahead and the lint output (on stdout) never reached the model; `dangerous-cmd-warn`
  wrote its reason to stdout, hard-blocked `uv venv`, `python -m venv`, `printenv HOME`,
  `cat .env.example` and `git push --force-with-lease`, and its UPDATE-without-WHERE
  guard used a lookahead `grep -E` cannot parse, so it never fired. New
  `tests/hooks.sh` pins every one of these (26 assertions; 17 of them fail against the
  old hooks) and runs in `just check` and CI. `hooks/README.md` wiring examples and the
  sample scripts moved off the old string-list format and non-existent
  `$TOOL_INPUT`/`$FILE_PATH` variables; a new section documents the stdin fields and
  exit codes. `tests/check-exec-bits.sh` now also covers `hooks/*.sh`, as AGENTS.md
  had always claimed - 11 of 13 hooks were tracked 100644 (harmless while every
  wiring calls `bash hooks/x.sh`, but the documented gate did not exist).

- **`fleet prune` classified live sessions' worktrees SAFE** - a real dry run
  marked 12 of 17 worktrees removable, five of them the cwd of an open session
  and two of those running; `--remove` would have stranded both in the silent
  CPU spin the skill documents. `sessions.sh` read only the first Desktop
  session store it found, while the owners lived in a second Desktop
  instance's (`--user-data-dir`) store; it joined ownership on branch alone,
  never on the session's cwd; and it took liveness from a wrapper timestamp
  Desktop only rewrites at turn boundaries. It now reads every instance's
  store, attributes worktrees by branch, cwd, worktreePath, transcript
  directory and live cwd, and takes liveness from the transcript too - which
  also arms `fleet land`'s live-owner gate against mid-turn and
  other-instance sessions. A `.claude/worktrees/` tree no session record
  claims is now REVIEW, never SAFE; `--remove` re-classifies against a
  forced-fresh scan before deleting; and the index cache is keyed by the
  stores it scanned, so a fixture run can no longer poison a real one.
  `sessions.sh stores` and `fleet config` now say which stores answered.

- **`fleet land` merged under a live session working in the lane's worktree** -
  the live-owner gate still joined owners on branch alone, so the two shapes
  the prune fix cured - wrapper branch drift (a session in worktree
  `vigilant-grothendieck` recording branch `claude/keen-mccarthy`) and a session
  that `EnterWorktree`'d into a lane, which only its transcript records - left
  a live writer invisible: the land merged, then rebased its tree. The gate
  now also treats any live directory claim on the lane branch's worktree as an
  owner, read through the new `sessions.sh at --fresh`: the cached index may
  nominate claimants but every one's liveness is re-read, and transcripts
  being written in the worktree are read straight off disk (seconds, against
  60s for a fresh full scan). The self-exemption holds only when self is the
  sole live claimant by either join. Liveness re-reads are batched
  (`live_many`, one walk for any number of sessions, where each used to cost
  ~3s), and `worktree_path_for` no longer cuts a worktree path at its first
  space.

- **The `fleet start` daemon ignored SIGTERM and SIGHUP and kept landing as a
  ghost** - its handler removed `daemon.pid` and then resumed, because a trapped
  signal returns to the script. A daemon whose session ended (SIGHUP) kept
  polling, invisible to `fleet stop` ("no daemon running") and to the
  double-start guard, and landed a lane 3s later; every `fleet stop` was really
  its SIGKILL escalation. A signal is now a stop request honoured between
  lands: a land in progress finishes through its gate, no new one starts, and
  an idle daemon answers during its poll sleep instead of after it. The
  fleet-ops e2e (`tests/skills/functional/fleet-ops/e2e.sh`), which no gate
  ran and which had drifted to 7 FAILs, is repaired and now runs in
  `tests/run-skill-tests.sh`.

### Changed

- **`craftcms-ops` refreshed for real agency builds.** Ten new one-topic references -
  SEOmatic, Blitz, Formie, CKEditor, DDEV, Codeception, Twig output security,
  craft-vite, the 3 → 4 → 5 upgrade path, and Craft-side performance - plus the old
  two-topic files split into element queries, GraphQL, and plugin development. Facts
  checked against the vendor docs and Packagist on 2026-10-05, which corrected several
  common assumptions: Blitz Hints was removed in 5.10, Blitz won't cache pages with
  pending transform URLs, CKEditor plugin 5.x dropped global configs, Craft 5 GraphQL
  types lost their section prefix, and Vite 5+ moved the manifest under `.vite/`.
  A new `check-craft-facts.py` verifier keeps the Craft and plugin majors honest
  (offline in PR CI, live against Packagist in the weekly freshness job). The
  description now carries its own "Use when" trigger, with no separate `when_to_use`.
- **`security-ops` fits the compaction budget.** The three T2 audit-agent prompts, the
  T3 remediation preflight and the report template moved verbatim to
  `references/audit-agent-prompts.md`; `SKILL.md` keeps routing, tiers, detection,
  consolidation and a one-table summary of what each agent reads and reports. The body
  drops from about 5,200 to 3,400 estimated tokens, under the 5,000 Claude Code keeps
  after auto-compaction, so the orchestration no longer falls off the end.
- **`security-ops` references split to a 300-line ceiling.** The OWASP guide is now
  `owasp-top10-a01-a05.md` + `owasp-top10-a06-a10.md` (the `review`, `testgen` and
  `techdebt` preloads point at both), MFA/rate-limiting/lockout moved to
  `auth-account-protection.md`, and every reference over 100 lines opens with a
  Contents list. The skill's suite now fails on an over-length reference, a stale
  Contents list, a repo citation of a reference that no longer exists, or a
  secret-shaped example value.
- **`supply-chain-defense` and `prompt-injection-defense` are self-contained and
  portable** - each folder now runs when copied alone into another plugin. Both ship
  `scripts/run-python.sh`, which runs the `.py` scripts with the first of
  `python3`/`python`/`py` that is really Python 3.8+ (on Windows `python3` is often the
  Microsoft Store alias, which exits 49 without running anything); the copies are
  duplicated on purpose and `tests/check-resources.sh` fails if they drift. Every doc
  example launches through it. Each suite gains a "standalone" block that copies the
  folder alone and runs every script's `--help` and offline mode. Both SKILL.md files
  now lead with the procedure and decision tables and push depth into references
  (supply-chain-defense ~9.6k -> ~3.6k estimated tokens), with no content dropped: workflows A-L and the script / hook /
  portability detail move to new references, and the three references over 300 lines
  split by topic (`tooling-by-layer.md`, `repo-integrity-response.md`,
  `line-breaks-and-controls.md`, `codepoint-bands.md`). Every reference over 100 lines
  carries a table of contents, and both descriptions carry a "Use when" clause.

- **Rules made machine- and person-agnostic.** Rules ship in a public plugin, so
  author-specific incidents, repos and phrasing ("the user corrected this on…") are
  retold generically with the lesson kept: `release-review`, `public-posts`,
  `worktree-boundaries`, `modern-tools`, `shell-preference` and `agentic-quality`.
  `worktree-boundaries` also stops asserting that chips never isolate - whether a
  chip gets its own worktree depends on how it is started, so the directive is to
  seed every chip prompt to create its own lane rather than to assume either way.
- **`public-posts` exempts replies on an automated reviewer's threads** - answering
  an AI code-review bot's finding with evidence on a PR you are working on is the
  PR's working record, not a statement to a third party, and a review-triage or
  CI-autofix flow depends on it. Human-started threads and other people's PRs still
  need the preview.
- **`agentic-quality` rule gains a Tests section** - "evidence, not ceremony". Agents
  over-produce tests that restate the code they were written after: they always pass,
  catch nothing, and break on every refactor. The section rewards signal over count:
  every new test must be seen failing (against the unfixed or a deliberately broken
  version), is named for the bug it prevents, starts from a written list of failure
  modes, tests at the boundary users hit, stays small (1-3 per behaviour change, no
  coverage targets, no new framework inside a feature PR), ends E2E runs with a
  checkable artifact, and treats deleting a redundant test as an improvement - culled
  one module per PR with revert-and-run evidence, never a repo-wide sweep. Test naming
  moved here from the Structure section so it is stated once; the self-check gains
  "have I seen it fail?".

## [3.8.0] - 2026-08-31

Four new skills, and three existing ones realigned against a reality that moved
underneath them.

### Added

- **`a11y-ops` skill** - web accessibility as a legal requirement with dates
  attached, not a quality preference. Two facts frame it: automated tooling
  finds only ~30-40% of WCAG failures, so a green axe run is a floor rather
  than a result; and almost every failure traces back to a `<div>` replacing a
  native element and rebuilding a fraction of what it provided. Carries the
  standards map (WCAG 2.2's nine new criteria and why 4.1.1 was removed; EAA
  extraterritorial reach, penalties and the EN 301 549 v4.1.1 move to WCAG 2.2;
  **ADA Title II deadlines extended by the DOJ on 2026-04-20 to 26 Apr 2027 /
  2028** - most published advice still quotes the old dates), a four-pass audit
  workflow with what each pass can and cannot detect, twelve recurring failures
  with class-level fixes, and a deliberately honest accessibility-statement
  template. Ships `scan-a11y.py`: a static pre-flight over
  HTML/JSX/Vue/Svelte/Astro source with fifteen conservative rules, severity and
  rule filtering, a JSON envelope and exit 10 as the CI signal - and a test
  suite that asserts zero false positives on correct markup, because a linter
  that cries wolf gets muted.

- **`evals-ops` skill** - the eval harness discipline that everything else in
  agent engineering depends on: you cannot tune a prompt, retriever or memory
  layer without a measurable suite. Covers the three levels most teams collapse
  into one (outcome vs step vs trajectory, and the *lucky pass* that
  outcome-only scoring banks as a win), golden-set construction as four
  deliberate buckets with freeze discipline (a set that grows every sprint
  cannot tell you whether the system or the set moved), the documented
  LLM-as-a-judge biases and when a lens-diverse panel beats N identical judges,
  adversarial refute-not-confirm verification, and the tier ladder that keeps a
  CI gate alive - deterministic checks block, judge metrics start advisory,
  thresholds sit below the *measured* noise floor. Ships
  `judge-calibration.py` (Cohen kappa vs human labels, per-class confusion,
  verbosity/position bias probes; exit 10 below `--min-kappa`) and
  `goldenset-audit.py` (duplicates, bucket skew, staleness, and freeze-manifest
  drift that catches a frozen case edited in place to make it pass).

  Also covers RAG (`retrieval-eval.md` - recall@k, the retrieval-vs-generation
  2x2 that stops two independent bugs being averaged into one number, and the
  unanswerable-question bucket almost everyone omits, without which a suite
  cannot detect hallucination under retrieval failure) and the labelling step
  itself (`annotation-workflow.md` - the human-human agreement ceiling a judge
  mathematically cannot beat, stratified sampling across the judge's own
  verdicts, adjudication, and annotator drift).

  A third script, `eval-baseline.py`, derives the baseline and noise floor from
  the rolling run history, prints the threshold a gate should actually use, and
  runs McNemar's exact test over paired per-case results. The point: a change
  that breaks 8 cases and fixes 7 moves the headline score by 0.01 and is
  invisible to any score comparison, while the paired view names all 15 - and
  honestly reports p=1.0, because churn is not a regression. Exit 10 on a
  confirmed regression or a cost/latency ceiling breach.

  Four copy-and-adapt assets, so the first hour goes on deciding what to measure
  rather than on scaffolding: a 12-case starter golden set spanning all four
  buckets (and passing the skill's own auditor - enforced in CI, because an asset
  the skill's tools reject is worse than no asset), the 40-line runner the skill
  tells you to start with, a one-criterion judge rubric carrying the bias-counter
  instructions and calibration checklist, and a GitHub Actions workflow encoding
  the tier ladder.

  Finally, `hillclimbing.md` and a two-way seam with `iterate`. Optimising against
  an eval is where a good suite gets destroyed, and neither skill knew the other
  existed: `iterate` keeps a change when the metric beats the previous best, which
  is correct for line coverage and a coin flip for a score with run-to-run
  variance - point it at an eval and roughly half its "improvements" are noise,
  banked with perfect discipline. `eval-baseline.py --accept` is the fix, and it
  deliberately inverts the exit semantics: CI asks "did this get worse" (noise is
  fine), a hillclimb asks "is this improvement real" (noise is not). `iterate`
  gains a Noisy Metrics section pointing at it; the reference owns the discipline
  `iterate` cannot - train/validation/held-out splits, the held-out look budget,
  and why a single `iterate/best` champion is a local-optimum trap where a Pareto
  frontier is not. Grounded in GEPA (arXiv:2507.19457, ICLR 2026 Oral), whose
  documented verbosity-overfit failure mode and never-shown-to-the-reflector
  validation split are the citable versions of both arguments. Carries an explicit
  extraction trigger for a future `prompt-optimization-ops` rather than pre-empting
  one. Suite 97 -> 109 assertions.

- **`nextjs-ops` skill** - the framework underneath `payloadcms-ops` had no skill
  of its own. Covers the server/client boundary and what actually crosses it, the
  two caching models (`use cache` / `cacheComponents` alongside the older
  `unstable_cache` and `revalidateTag` forms) as the section the skill exists
  for, Server Actions as public endpoints with the security posture that
  implies, streaming and Suspense boundaries, the `middleware.ts` -> `proxy.ts`
  move, and self-hosting beyond Vercel. Audit rules gate on the project's
  detected Next.js major rather than assuming the latest.

- **`icon-ops` skill** - sourcing, vetting and shipping SVG icons for web UI.
  Covers the four decisions that lock an icon set (grid, family, stroke width,
  corner language), the two licence traps that actually bite (a brand mark is a
  trademark whatever the file licence says; aggregators like Iconify hide which
  set's licence applies), `currentColor` theming, the delivery matrix including
  why icon fonts fail and why an external `<use>` is CORS-blocked in production,
  and the two accessibility cases - with the counter-intuitive rule that the SVG
  stays `aria-hidden` in both and the name goes on the control. Ships
  `normalize-icon.py` (strips editor cruft, rebinds literal colours to
  `currentColor`, drops fixed sizing, applies a11y attributes; `--check` as a CI
  gate, `--symbol` for sprite assembly, idempotent) and a commented sprite
  scaffold.

- **Skill-internal link gate.** `doc-drift.sh` checked markdown links in
  `README.md` and `AGENTS.md` only, so links *inside* skills rotted unseen - four
  had, including a `fleet-ops` pointer to a rule that was never shipped to this
  repo and a `ytdlp-ops` pointer to a skill that was extracted to its own. The
  gate now resolves every link inside `skills/**` relative to its containing
  file. Deliberately narrow: it flags only links that fail to resolve, not the
  82 legitimate cross-skill references that climb out of their own directory.

### Changed

- **`claude-api-ops` gains context-engineering doctrine.** The discipline that
  replaced prompt engineering in 2026: deciding what the model sees on every
  call, and treating the window as a budget with three tiers (in-context /
  on-disk / retrieved). The load-bearing and counter-intuitive part is that under
  modern prompt caching, keeping full history has been measured to beat
  summarisation on cost, latency *and* recall at once - so compaction is a
  deliberate response to a named constraint, not a reflex. Also retargeted at the
  Claude 5 lineup.

- **`loop-ops` accounts for native scheduling primitives** - "native primitives
  schedule; loop-ops governs", the same repositioning `fleet-ops` took against
  agent teams. It was written when scheduling was something you wired up
  externally; Claude Code has since shipped `CronCreate`, a scheduled-tasks MCP
  surface and `/loop` as a bundled skill with a self-pacing dynamic mode. The
  plumbing is now the harness's job. The durable value - the L1/L2/L3 risk ladder,
  the STATE/run-log/budget spine, the kill switch and the escalation gate - is
  what the skill keeps.

- **`windows-ops`: steady-state process triage** - the skill covered boot- and
  crash-time only, so a workstation pinned by already-running processes did not
  route to it. Adds `process-triage.ps1` (samples CPU twice and reports
  percent-of-one-core, private commit, age and orphan status; exit 10 on
  findings; `-Tree` emits a leaves-first termination order) plus
  `references/process-triage.md`. The load-bearing part is the safety guard:
  the script resolves the calling session's own ancestry and marks it
  `protected`, because the failure it exists to prevent is an agent killing the
  process chain it is running in. Encodes a measured incident - six spinners
  with LIVE parents held five cores for 43.8 hours while a dead-parent orphan
  scan reported 1.16 GB, which is why the technique is rate, not lineage.

- **`fleet-ops`: worktree-teardown ordering landmine** - removing a lane
  worktree while its session is attached does not kill the session; it spins at
  ~85% of a core indefinitely against the deleted path.

- **Skill description budget raised 700 -> 1000 chars per skill.** The 700 cap
  from the 2026-07 trim proved too tight for skills with a genuinely broad
  trigger surface, and cutting real trigger phrases costs more in missed routing
  than it saves in tokens. The catalog-wide soft budget is unchanged.

### Fixed

- **`evals-ops`: nine defects found by adversarially reviewing the skill against
  its own doctrine.** Refute-don't-confirm, applied to the thing that preaches
  it. Seven were in the scripts and **all of them failed OPEN** - reporting
  "fine" while measuring nothing, which is the dangerous direction for a gate:
  - `eval-baseline.py` treated a *measured* spread of exactly 0.0 as "no data"
    (`if spread:` is falsy at zero), so a deterministic or genuinely stable
    suite reported INSUFFICIENT-DATA and exited 0 on an unambiguous 0.90 -> 0.70
    collapse. Zero variance is the most informative history there is.
  - An integer case id of `0` was dropped from the paired test (`if r.get("id")`
    is falsy), hiding real regressions. Ids are now membership-tested and
    stringified so `1` and `"1"` pair.
  - A `null` or JSON-string score in the history file was ignored silently;
    now reported.
  - The exact McNemar test is O(n) big-integer work over `2**n` - measured at
    133 ms for 2,000 discordant pairs but **~100 seconds for 20,000**, i.e. a CI
    hang. Switches to a continuity-corrected normal approximation above 1,000
    pairs and reports which method it used.
  - `goldenset-audit.py` hashed `_line` and `id` as part of a case's content, so
    `DUPLICATE_CASE` could never fire on the one thing it exists to catch: the
    same case under two ids.
  - `judge-calibration.py` read `"length": true` as a length of 1.0 (bool is a
    subclass of int) and emitted a confident, meaningless -0.87 verbosity
    correlation.
  - The shipped CI template asserted unverified GitHub Action majors -
    precisely the staleness trap this repo has a verifier doctrine about - and
    hard-coded a vendored script path that contradicted the one `iterate`
    documents. Both are now flagged ADAPT points behind one `$EVALS_OPS` var.
  - `golden-datasets.md` stated bucket *targets* (production 40-50%) while the
    auditor warned on a wider *band* (30-65%) with nothing saying the two
    numbers differed on purpose. Both are now named, and a warning quotes the
    target it is measured against.

  All nine are pinned by named regression assertions, and the four sharpest were
  mutation-tested - the fix reverted, the suite confirmed red - because an
  assertion that cannot fail is not a test. That step earned its cost
  immediately: the duplicate-hash assertion passed against deliberately re-broken
  code, because its fixture carried an `expected` field and so exercised the
  wrong branch of a two-branch function. A tenth defect, in the test for the
  ninth. Fixture corrected and the reason written next to it. Suite 109 -> 127.

- **`install.ps1` silently dropped bracketed paths.** `[` and `]` are PowerShell
  wildcards, so `Copy-Item -Path` on a path like `app/shop/[slug]/page.tsx`
  matched nothing, copied nothing and raised no error - files were simply absent
  from the installed skill. Switched to `-LiteralPath`. Also gains a staleness
  guard and a doctor mode.

- **`fleet-worker`'s test suite was environment-dependent.** Three assertions
  failed on a host that exports `FLEET_WORKER_KEYRING_SERVICE`/`KEY` and passed
  in CI, because the suite's own mock `keyring` then pre-empted the ZHIPU/GLM
  branches those assertions exist to test. The suite now clears every env knob it
  derives from the scripts themselves, and asserts hermeticity first so the
  symptom is one honest failure rather than three misleading ones.

- **`payloadcms-ops`** updated to the Next.js 16 `revalidateTag` form.

## [3.7.0] - 2026-08-15

### Added

- **`cloudflare-ops`: `workers-runtime-gotchas` reference** - battle-tested
  Workers runtime footguns mined from a production multi-tenant Worker, each
  with symptom/why/fix: detached `fetch` ("Illegal invocation" — shipped three
  times before the guard-comment pattern), per-colo `caches` vs KV vs D1
  (short-TTL read-collapse worked example), `waitUntil` as latency
  optimisation with the D1 outbox + cron re-drain as the guarantee, testing
  cron `scheduled()` handlers under vitest-pool-workers (thin dispatcher,
  self-guarding jobs), the test workerd lagging production (stub-passes /
  binding-fails, `wrangler dev` smoke → post-deploy log check ladder), Email
  Service's two account states + the `E_SENDER_NOT_VERIFIED` silent-failure
  trap, Smart Placement (run near the data; concentrates the per-colo cache),
  and `wrangler dev` rewriting the request host to the `[[routes]]` pattern
  (host-keyed logic silently takes the production branch locally; `dev.host` /
  `--local-upstream`). SKILL.md reference index + Common Gotchas pointer
  updated.

- **`hono-ops` skill** - Hono v4 on Cloudflare Workers, distilled from a
  production multi-tenant Worker (one app, 6+ mounted sub-apps, ~1350 tests):
  app composition with typed `Bindings`/`Variables` and sub-app mounting,
  middleware ordering as the security topology (auth middleware that builds a
  scoped per-request world; bearer-auth surfaces mounted *outside* the session
  boundary), typed errors → one `onError` mapping, the JSON-404-vs-SPA-shell
  split, zValidator vs hand-rolled validation trade-offs, SPA co-serving via
  the static assets binding, `hc` RPC vs hand-rolled typed clients,
  vitest-pool-workers testing (migrations, JWT harness, workerd version lag),
  streaming/SSE/WebSockets, Durable Objects (Hono-in-a-DO, hibernated
  WebSockets, alarms, vs RPC methods), OpenAPI (`@hono/zod-openapi`
  schema-first vs annotations vs skipping it), CORS + a production middleware
  stack, `hono/jsx` SSR (jsxRenderer layouts, Suspense streaming, the
  don't-grow-a-SPA-here scope guard), Node/Bun/Deno adapter deltas with a
  Workers→Node porting checklist, and the Workers gotchas (detached fetch
  "Illegal invocation", immutable headers, per-colo `caches`, `waitUntil`).
  Twelve references, two
  commented starter templates (composition root + vitest-pool-workers
  config), a `route-inventory.py` scanner with three registration-order
  lints (exit 10: `bypass` = route dodges a later middleware, `duplicate` =
  dead re-registration, `shadowed` = unreachable route), a
  `check-hono-facts.py` staleness verifier (offline in PR CI, live in the
  freshness workflow), and a 60-assertion offline suite.

- **`agentic-quality` rule** - cross-repo doctrine for code, comments, docs, and
  structure that survive the session: the cold-agent test, comment doctrine
  (contract blocks, WHY-only inline, guard comments, section markers,
  format-at-site, citations), entry-doc standard (AGENTS.md + Landmines,
  CLAUDE.md deltas-only, nesting policy), file-size discipline, docs indexing,
  doc-commit pairing, and monorepo directives. Grounded in a 10-repo audit.

- **`repo-doctor` skill** - read-only auditor scoring any repo against the
  doctrine across six weighted dimensions (entry docs, docs health, comments,
  structure, enforcement, doc pairing) with a TTY panel, `--json` envelope
  (`claude-mods.repo-doctor/v1`), and `--strict` CI gate. Ships four references
  (comment-doctrine, entry-docs, monorepo-structure, scoring-rubric), AGENTS.md +
  docs-index templates, and a 10-assertion offline suite.

- **`rembg-ops` skill** - transparent-PNG cutouts for flat illustration,
  sticker, and avatar art, with a deterministic fallback ladder past rembg's
  ML failure modes so batch jobs degrade predictably on non-photographic input.

- **Context-aware statusline template** - `templates/settings.json` ships a
  statusline; `install.ps1` wires it merge-if-absent, opt-in via flag.

- **`CONTRIBUTING.md`** - issue-first for non-trivial PRs, Conventional
  Commits, the `just check` gate, and the no-translations policy (fast-moving
  docs make committed translations stale within days).

### Changed

- **`sqlite-ops`** — new `references/d1-production-patterns.md`: three
  incident-derived Cloudflare D1 patterns (symptom → why → procedure) mined from
  a production multi-tenant Worker. (1) `wrangler d1 migrations apply --remote`
  can time out yet still apply — verify remote schema state read-only before
  re-running; (2) `.batch()` rolls back on SQL error but a scoped
  UPDATE/DELETE matching 0 rows is NOT an error — check `meta.changes`,
  post-verify, compensate; treat 0 changes as 403/conflict, never success;
  (3) read replication via the Sessions API as opt-in-to-replica — default
  `first-primary`, replica only for allowlisted display-only GETs, bookmark
  cookie for read-your-writes, so a misclassified route degrades to slower,
  never staler. Cross-linked from `d1-edge.md` (batching, Sessions API, deploy
  gate) and `migration-patterns.md`; indexed in SKILL.md with two new gotcha
  rows; the reference-wiring test now gates the new file.

- **`typescript-ops`: TS 7 native-compiler reference**
  (`references/ts7-native-compiler.md`) - fresh adoption knowledge for the
  Go-native `typescript@7` (stable since 2026-07-08): the no-JS-API break
  (`require('typescript')` throws MODULE_NOT_FOUND on 7.0.x; AST-free /
  alt-parser / alias workarounds), the dual-install `tsc` bin ambiguity
  (explicit compiler paths while a `typescript5` fallback alias exists),
  the embedded-language ecosystem lockout until 7.1+ (vue-tsc, svelte-check,
  Astro, MDX pinned to TS 6), and a measured 12.1x production adoption with
  a go/no-go checklist. Point-in-time sections are marked verify-on-apply.
  SKILL.md gains a TS 7 section, the facts catalog moves typescript's
  documented major 6 -> 7, and the skill's staleness verifier is now wired
  into `tests/check-resources.sh` (offline, PR CI) and `freshness.yml`
  (live) - it previously ran only in the skill's own suite.

- **`auth-ops` skill: two new references.** `references/cloudflare-access.md`
  — identity-aware proxies worked through Cloudflare Access: app/policy
  anatomy (team domain, per-hostname AUD tags, IdP vs one-time-PIN policies),
  origin-side `Cf-Access-Jwt-Assertion` verification with jose (cached JWKS,
  kid-triggered refetch), the closed-origin trust precondition
  (`workers_dev = false` generalized to any IAP), fail-closed identity → user
  → scope layering, Service Auth/Bypass for bearer-token machine routes, and
  the local-dev tunnel-or-doubly-gated-stub problem. `references/better-auth.md`
  — the Better Auth TypeScript library at the architectural level (explicit
  verify-against-current-docs note): server instance + client pairing, database
  adapters and CLI schema generation, DB-backed sessions with cookie caching,
  email/password + social providers, passkey/2FA/organization plugins, Hono
  and framework mounting, and choosing it vs hand-rolled vs a hosted IdP.
  Facts verified against live Cloudflare docs and better-auth.com (2026-08):
  Access token claims incl. the ~1KB `custom`-claim trim, service-token
  `common_name` verification, `/cdn-cgi/access/logout`, the SPA
  302-to-IdP/CORS trap, and Better Auth's session options
  (`expiresIn`/`updateAge`/`cookieCache`), plugin catalog (incl. sso/scim),
  and migration guides. Frontmatter triggers extended (cloudflare access,
  zero trust, identity-aware proxy, AUD tag, service auth, better auth),
  the decision tree and body gain an IAP branch + quick reference, and
  cloudflare-ops cross-points to the new Access reference.

- **fleet-ops landing wave** - session-aware landing gate with a
  self-ownership exemption, `MAIN` role for the integration checkout,
  `fleet prune` for stale worktree housekeeping, config now reaching the
  script, a higher session-cache TTL, and refusal to land when the test gate
  is unarmed rather than passing vacuously.

- **fleet-worker default model** - GLM-5.2 -> GLM-5.3 (verified live
  2026-08-14).

### Removed

- **`fleetflow` skill extracted to its own repo**
  ([github.com/0xDarkMatter/fleetflow](https://github.com/0xDarkMatter/fleetflow)) with
  full history via `git subtree split` (36+ commits) — an app with a live
  service (the machine-wide dashboard at `https://fleetflow.lab`), its own
  server (`ff-serve.py` + `ff-aggregate.py` + `ff-archive.sh`, recovered from
  the authoring session's transcript after the 2026-08-01 installer incident
  destroyed the unversioned machine-local copies), and a growing surface is a
  product, not a skill resource (the iso-studio rule). Still invocable as
  `/fleetflow`: `~/.claude/skills/fleetflow` is now a junction to the repo,
  and the `fleetflow` Process Compose service runs from the repo directly.
  Skill count 103 → 102. The never-released "Added" entry for fleetflow that
  previously sat in this section travels with the extraction — its narrative
  lives in the new repo's README and git history.

### Fixed

- **Output styles** - frontmatter `name:` now matches each filename in all
  13 styles. `outputStyle` resolves case-sensitively against `name:` and fails
  silently on mismatch, so every capitalised name made the documented setting
  value a no-op; a validate.sh gate now blocks the drift returning.

## [3.6.0] - 2026-07-04

### Added
- **`svg-brand-tint-ops` skill** - zero-dependency in-browser SVG studio.
  Recolour any SVG to a brand palette via a token-driven tri-tone
  (`feColorMatrix` desaturate → `feComponentTransfer` grey-ramp remap →
  theme-aware CSS-filter bake), plus a from-scratch raster vectoriser
  (PNG → SVG): a Potrace-paper geometry stage (tolerance-tube straightness,
  penalty-DP optimal polygon, sub-pixel vertex adjustment, alphamax corners —
  reimplemented from Selinger 2003, no GPL code) over soft-field marching
  squares with alpha-aware palette handling (matte de-blending, anti-alias
  fringe cull, blend-veto). B&W / posterised / colour trace modes, a
  photographic filter stack, curated Google Fonts on SVG `<text>`, element
  hover-inspect, before/after split, palette-from-image, and SVG/PNG export.
  Ships a ~90-line dependency-free static server (`scripts/server.mjs`), a
  headless trace CLI (`scripts/trace.mjs`) sharing one canonical engine with
  the browser tool (`assets/trace-core.mjs`), a colour-math + trace + theme
  reference, and a 22-assertion offline test suite.

## [3.5.0] - 2026-07-03

### Added
- **`isometric-ops` skill** - creation, refinement, composition, and export of
  isometric illustrative assets for websites and games. 14 reference files carry
  the exact projection math (true isometric 30° vs 2:1 dimetric 26.565° vs
  pixel-neat 1:2 — with every constant derived and machine-checked), coordinate
  transforms + y-sort depth doctrine, the tile-spec discipline that prevents
  misaligned tilesets, SVG/CSS/three.js generation routes, pixel-art (Aseprite)
  workflow, dual Blender ortho rigs (60° dimetric vs 54.736° true iso — a
  distinction most tutorials gloss), engine tilemaps (Godot 4 / Unity / Phaser 3),
  the AI pipeline (Recraft/Midjourney/Flux+LoRA with ControlNet depth/MLSD
  structure control, upscale + vectorization ladders), asset sourcing with
  AI-training-clause licence discipline, and a curated prompt library. Four
  Resource-Protocol scripts: `iso-math.py` (constants, transforms, SVG grid
  generator, per-tool transform recipes), `tile-validate.py` (AI-tile QA gate:
  halo/bleed/anchor/palette), `sheet-pack.py` (spritesheet + JSON atlas), and a
  `check-iso-facts.py` §7 staleness verifier (`--offline` gates PR CI on the
  canonical constants; `--live` resolves cited npm packages weekly). The
  companion **iso-studio** app — a zero-dependency browser scene composer
  (snap-to-grid staging, footprint-aware y-sort, control palettes,
  PNG/SVG/scene-JSON export, and blockout-to-ControlNet depth/lineart export)
  — was built alongside and immediately extracted to its own repository
  (github.com/0xDarkMatter/iso-studio) because an app with a roadmap and an
  asset library is a product, not a skill resource; the skill routes to it via
  `references/iso-studio.md`. Built by a file-partitioned Opus/Sonnet agent
  workflow with per-file adversarial review against a pinned-constants build
  brief.

## [3.4.0] - 2026-06-23

### Added
- **`r-ops` skill** - the set's first data-science skill: a tidyverse-first,
  current-best-practice reference for modern R (2024+). `SKILL.md` routes an
  import → tidy → transform → visualize → model → communicate workflow across
  9 reference files (~115 KB): tidyverse-core, import-io, strings-dates-factors,
  visualization, iteration-functional, modeling-stats, data-table, time-series,
  workflow-tooling. Leads with current idioms (native `|>`, dplyr `.by=`, the
  `\(x)` lambda, `across()`, `list_rbind`, `slice_*`, tidymodels, tsibble/fable,
  Quarto + renv); names base R and `data.table` where they win. Ships a
  43-assertion offline self-test and a `check-r-facts.py` §7 staleness verifier:
  `--offline` (PR CI) asserts every CRAN package in `assets/r-packages.json` is
  still named in the prose and the currency note carries a year; `--live`
  (weekly freshness, never blocks a PR) resolves each package on CRAN, exit 10
  if one is archived/removed, exit 7 if CRAN is unreachable. Salvaged and
  freshened from the stale stacked PR #6 (which also duplicated the
  already-shipped supply-chain-defense); re-landed clean off current `main`.

## [3.3.0] - 2026-06-22

### Added
- **`loop-ops` skill** - the *outer-loop* design discipline, twin to `iterate` (the inner
  loop). Where `iterate` drives one metric in one session, `loop-ops` is the orchestration
  layer above it: how to design, scaffold, cost, and safely run scheduled
  discover→triage→implement→verify→escalate-or-land agent loops. Its spine is the
  **risk-tier ladder** (L1 report → L2 assisted → L3 unattended) mapped onto Claude Code's
  *actual* permission model — each tier a concrete permission mode, plus the
  enumerate-vs-isolate fork and the load-bearing rule that a scheduler invokes `claude -p`,
  not a session that spawns ungated children (grounded in `docs/AUTO-MODE-CLASSIFIER.md`).
  Ships a STATE/run-log/budget state spine, a 7-pattern catalog (PR watch, CI watch,
  dependency bump, changelog gen, merge hygiene, issue/daily scan), multi-loop
  coordination + kill switch, and three Resource-Protocol scripts: `loop-scaffold` (scaffold),
  `loop-check` (readiness scorer — refuses a green light on an unbounded scope, missing gate,
  or undefined escalation), and `loop-estimate` (token-$ estimate by pattern × cadence × model,
  pricing sourced from `claude-api-ops`). Composes `fleet-worker` (spawn) and `fleet-ops`
  (land); 58-assertion offline self-test. Builds on the public *loop engineering*
  discipline (Steinberger, Osmani) and the [Ralph loop](https://ghuntley.com/ralph/).
- **`docs/AUTO-MODE-CLASSIFIER.md`** - reference on Claude Code's auto-mode permission
  classifier (the two-gate model, gating categories, legitimate-authorization decision tree),
  cited by `loop-ops` as the authority for its risk-tier mapping.
- **loop-ops hardening (world-class pass)**: `loop-doctor.sh` - a live preflight
  (`--offline`/`--live`) that proves a loop will *run* (gate binary on PATH, budget fits a
  tick, permission mode achievable, L3 isolation present), complementing loop-check's
  *well-formed* check; `loop-estimate.py` is now **caching-aware** - it models the static
  run-prompt prefix as a cache entry and the TTL-vs-cadence rule (a loop slower than ~1h
  can't cache), the key loop economics lever; and a companion **`rules/loop-engineering.md`**
  carries the graduated-autonomy directive (L1→L2→L3, scheduler-not-session, escalation
  gate, kill switch + budget) into every session, not just when the skill is invoked.
  Suite now 81 assertions.
- **loop-ops depth pass** (closing every gap vs the broader loop-engineering discipline):
  pattern-aware `loop-scaffold` (seeds a near-ready,
  audit-clean config per pattern, tier-aware, with a graduation block — vs upstream's
  static seeds); a complete **worked example** `assets/examples/pr-watch/` (filled
  config + populated STATE + run prompt + run-log + a scheduler workflow with the
  kill-switch gate and `dontAsk` allowlist baked in) that CI **dogfoods**
  (`loop-check` + `loop-doctor` run on it every build) — vs upstream's 9 static starter
  dirs; a `references/failure-modes.md` catalog (11 incident-shaped failures, each mapped
  to the control that catches it); connector/MCP least-privilege scoping + the auto-merge
  guard in `references/risk-tiers.md`; and an honest "why Claude Code-specific, not a
  multi-tool matrix" note. 92-assertion suite.
- **loop-ops native-first, runner-agnostic scheduling**: the cadence layer now leads with
  Claude Code's own primitives — `/loop` (in-session), **Desktop scheduled tasks** (local,
  unattended), `/schedule` cloud routines (with the load-bearing *fresh-clone, no-local-files*
  caveat surfaced), and `/goal` as the native completion gate — with `loop-scaffold` scaffolding
  an executable runner-agnostic `loop-run.sh` for external schedulers (cron / Task Scheduler /
  systemd / process-compose) and GitHub Actions demoted to one optional path. No GitHub
  Actions dependency anywhere. 96-assertion suite.
- **pattern catalog v2 (morphology + event-driven + new archetypes)**: patterns are now a
  generative **morphology** — `trigger` (cadence / **event** via a Channel / `goal`) ×
  `posture` (L1/L2/L3) × `locus` (connector→cloud / local→desktop) — not a flat list, so
  any point in the space composes. Adds the **event-driven trigger** (Channels: a CI/error/
  deploy webhook pushes the tick in — cheaper + faster than polling) and six archetypes
  beyond the GitHub-CI slice: `metric-chase` (drive a metric via `iterate`),
  `regression-watch` (benchmark/eval diff), `digest` (connector-only cloud routine for
  email/Asana), `backfill` (run-to-completion via `/goal`), `monitor` (event-driven
  triage), `freshness` (doc/dep drift). `loop-scaffold` seeds all 13, the cost model knows
  them, each carries its dominant failure mode + cost profile. 109-assertion suite.

## [3.2.0] - 2026-06-22

### Added
- **`fleet-worker` skill** - delegate tool-using, multi-step agent tasks to a cheaper
  headless Claude Code worker on a cheaper model — Anthropic Sonnet/Haiku, or a
  non-Anthropic endpoint (GLM via z.ai by default; any
  Anthropic-compatible endpoint via `ANTHROPIC_BASE_URL`). Each worker is a real
  `claude -p` carrying Claude Code's full tool harness but a "grunt" brain, isolated
  in its own git worktree + `CLAUDE_CONFIG_DIR` (the load-bearing auth-isolation
  finding - without it a host subscription token leaks to the endpoint and 401s). An
  Opus orchestrator fans workers out in parallel, gates raw results with
  `fleet-collect.sh` (the `is_error`-not-`subtype` footgun, encoded), and hands the
  winning branches to `fleet-ops` for test-gated landing - fleet-worker is the spawn
  layer fleet-ops disowns. Ships bash + PowerShell launchers, `fleet-doctor.sh`
  (offline structural / `--live` endpoint staleness verifier + the oauth-trap
  preflight), a sanitized design spec, the fleet-ops handoff recipes, and a
  34-assertion offline self-test. Provider-agnostic framing; carries a "know your
  terms" note (custom endpoints are documented Claude Code config; keep the
  orchestrator interactive or on an API key per Anthropic's automated-access terms).

## [3.1.0] - 2026-06-17

### Added
- **`mapbox-ops` skill** - advanced Mapbox GL JS toolkit for the web (v3, not the
  native SDKs): custom markers, thematic dataviz, 3D/terrain, cinematic camera, style
  composition, expressions, performance, and hard-won gotchas across 14 reference files.
  Ships a headless-Playwright map verifier (`screenshot_map.py` - asserts a marker
  projects to its lng/lat) and a stdlib-only `check-mapbox-facts.py` §7 staleness
  verifier: offline asserts the v3 Standard config enums, terrain tileset IDs, and
  weather/camera version gates stay internally consistent; live resolves the third-party
  style URLs and flags a GL JS major bump past v3. 37-assertion offline self-test.
- **`pypi-ops` skill** - publish Python packages to PyPI via OIDC Trusted Publishing
  with PEP 740 attestations (`gh-action-pypi-publish`), not stored API tokens. Covers
  first-publish pending-publisher setup, the invalid-publisher / already-exists failure
  ladder, TestPyPI dry runs, release-environment approval gates, local `uv publish` /
  `twine`, and a stale-OIDC-federation audit (the Mini Shai-Hulud publish-token vector).
- **`docs/SKILL-CREATION-PROTOCOL.md`** - the canonical "how to build a claude-mods
  skill" sequencing doc (warranted? → frontmatter → body → resources → tests → repo
  wiring → ship). Cites rather than restates the layer-owning docs (skill-creator,
  SKILL-SUBAGENT-REFERENCE, naming-conventions, SKILL-RESOURCE-PROTOCOL) and carries a
  precedence table for when they disagree. `skill-agent-updates.md` now routes here first.

### Changed (terminal output)
- **Terminal design system promoted from experimental to the standard** for claude-mods
  shell scripts (`docs/TERMINAL-DESIGN.md`), with the **enclosing panel as the default
  grammar**. The `github-ops` audit family (`repo-scorecard.sh`,
  `check-security-posture.sh`, `check-issues.sh`) now sources `skills/_lib/term.sh` and
  wraps its human output in the full `term_panel_open … term_panel_close` frame — brand
  header, `│` body rail, `term_section` sub-headers, colored `term_mark` rows, a score
  pip-bar, and a footer health indicator — matching the fleet-ops look. The `--json`/data
  product on stdout stays plain (stream separation preserved; verified zero ANSI on
  stdout). Every glyph falls back to ASCII under `TERM_ASCII=1` (a full scorecard renders
  pure-ASCII), and color follows the stderr TTY so piping `--json | jq` keeps framing colored.
- **`term.sh` additions**: `term_init` takes an optional fd (`term_init 2`) so
  stream-separated tools detect color on the stream the human actually sees; new
  `term_panel_line` (generic rail body-row, the open-ended counterpart to the
  branch-shaped `term_leaf_line`), `term_mark <ok|bad|warn|skip|na|unknown>` checklist
  primitive, a `TERM_ARROW` pointer glyph, and `github-ops`/`audit`/`supply-chain`/`net-ops`
  brand glyphs — all with registered ASCII proxies. github-ops test suite gained 6
  assertions (source-check + ASCII-fallback purity across panel + checklist primitives);
  40/40 offline.

### Fixed (docs)
- **`SKILL-SUBAGENT-REFERENCE.md` was self-contradictory and misleading** (surfaced by
  external PR #12): it declared "no other top-level keys are permitted" and its
  validation awk flagged `when_to_use`/`argument-hint`/`effort` as violations — yet those
  are documented *Claude Code* top-level fields the repo uses deliberately. Rewrote it to
  document **two layers** (the portable Agent Skills six-field minimum vs Claude Code's
  top-level superset), with a referenced field table, the precedence rule (Claude Code is
  our target → superset fields stay top-level), and an explicit warning that burying them
  under `metadata` *disables* them. Validation snippet now allowlists the superset and
  defers to `claude plugin validate`.

### Changed (docs review)
- Refreshed `WORKFLOWS.md` with a v3.0 orientation banner (skills-first; subagents are
  isolation/worker-only); fixed `naming-conventions.md` frontmatter example (metadata
  block, not top-level arrays); dated `RESERVED-COMMANDS.md`; noted `anthropic-skills-guide.md`
  as a vendored reference pointing at the creation protocol.
- Archived completed-migration docs to `docs/archive/`: `AGENT-SKILLS-COMPLIANCE-BRIEF.md`
  (spec migration done, CI-enforced) and `COMMAND-SKILL-PATTERN.md` (command→skill
  conversion done). docs/ top level is now 8 load-bearing docs + `archive/` + `references/`.

### Added
- **github-ops `repo-scorecard.sh`** (the audit capstone) - one read-only command
  for a scored repo-health report, fleet-aware. **Orchestrates** the existing
  auditors (`check-security-posture.sh`, `check-issues.sh`) rather than
  re-implementing them, and rolls five dimensions — security (w35), metadata
  (w25), release-consistency (w15), open-issues (w15), latest-Actions-run (w10) —
  into a 0–100 score + A–F grade with the top-3 fixes per repo. `--org` sweeps
  every non-archived repo into a matrix + roll-up (avg/median, worst repos, fleet
  open-alert total); `--min-score N` is a CI gate (exit 10 below N). An unreadable
  dimension scores zero ("n/a"), never a false-healthy. Read-only (CI-asserted);
  +15 test assertions (34 total). Now the headline of github-ops `audit` mode.
- **github-ops security-posture auditor** - `scripts/check-security-posture.sh`:
  read-only audit of a repo's GitHub security settings (Dependabot alerts +
  security updates, secret scanning + push protection, code scanning, private
  vulnerability reporting, SECURITY.md, default-branch protection). Three things
  make it more than a toggle-checker: **visibility-aware severity** (public-repo
  scanning gaps are findings; private-without-GHAS is a note, not a nag), **the
  exposure layer** (where a scanner is enabled it fetches open-alert counts + max
  severity — the real signal), and an **`--org` fleet sweep** that audits every
  non-archived repo you own in one pass. Emits the exact enable commands but never
  applies them (a CI-asserted read-only guarantee). Ships `assets/SECURITY.md.template`;
  wired into `audit` mode; +13 offline test assertions (19 total). Exit 10 on
  gaps/open-alerts, 7 when unavailable.
- **github-ops open-issue awareness** - `scripts/check-issues.sh` surfaces open
  issues you may not have seen (externally-authored + stale), read-only via
  `gh issue list`. Wired into the pre-push gate (`push-gate/preflight.sh`) as a
  post-gate **advisory** step: every push to a GitHub remote now flags unseen
  external/stale issues for that repo. Timeout-bounded, never changes the gate
  verdict, silent when gh is absent/unauthed or the remote isn't GitHub. Exit 10
  = issues to look at, 7 = unavailable (advisory). github-ops gains a 6-assertion
  offline test suite.
- **`okf-ops` skill** - assess, validate, and adopt the Open Knowledge Format
  (OKF) across markdown+frontmatter knowledge bases. `assess-okf.py` (read-only)
  scans a doc tree for OKF-readiness — frontmatter coverage, `type` presence, a
  key/value histogram, and a readiness % — so you can find good adoption
  candidates among many repos; `check-okf.py` validates a bundle for conformance
  (hard rules only, honouring OKF's permissive-consumption contract; `--strict`
  for CI gating). Honest scope baked in: OKF is a v0.1 draft, adopt per-repo not
  blanket. Both tools built to the Skill Resource Protocol; OKF format reference +
  copy-ready concept template; 10-assertion offline self-test.
- **`adr-ops` skill** - Architecture Decision Records as a cross-project workflow,
  generalized from a mature in-house ADR protocol: when-to-write / when-NOT
  decision rule, the canonical format (BLUF-first `## Decision`, fixed section
  order, frontmatter field set), the proposed→accepted→superseded/deprecated
  lifecycle, and append-only supersession discipline. Five tools to the Skill
  Resource Protocol:
  - `adr-init.sh` - bootstrap ADRs in a repo adopting them cold (dir +
    lint-clean ADR-001 + generated README)
  - `adr-new.sh` - scaffold the next sequential ADR (atomic, no-clobber,
    `--apply-supersede` flips the superseded record's frontmatter)
  - `adr-index.sh` - read-only index table from frontmatter; `--output` writes
    a generated Markdown index
  - `adr-touching.py` - query the `touches:` discovery surface ("what ADRs
    govern this path before I change it?"); exit 10 when a governing ADR exists,
    a usable pre-edit/CI guard
  - `adr-lint.py` - validates required fields, status enum, numbering, section
    order, cross-file supersession bidirectionality, lifecycle consistency
    (status vs `superseded-by`), and stale-`touches` paths
  Includes a CI-integration section (gate `adr-lint --strict` on exit 10).
  72-assertion offline self-test.

## [3.0.0] - 2026-06-10

### Added (media stack)
- **`ytdlp-ops` skill** - yt-dlp as the media ACQUISITION layer feeding
  ffmpeg-ops: format selection doctrine (`-S` sort over `-f` filters, codec
  targeting that avoids post-download transcodes), `--download-sections`
  clip-at-download, audio-only STT extraction (`-x --audio-format opus` =
  stream copy), playlist + `--download-archive` incremental channel syncs
  (`--break-on-existing --lazy-playlist` cron pattern), cookies/auth
  (`--cookies-from-browser`, Chrome 127+ Windows caveat, ban avoidance),
  rate limiting/politeness, SponsorBlock mark-vs-remove, output-template
  conventions (`[%(id)s]`, byte-safe `.100B` truncation), subtitles-as-cheap-
  transcripts, remux-vs-recode doctrine, livestream/premiere capture
  (`--live-from-start`, `--wait-for-video`), batch dry-runs (`--print
  filename`), a beyond-YouTube note, and a failure-triage ladder (the
  nsig/403/429/geo classes incl. TLS-fingerprint blocks → `--impersonate`,
  and the EJS class: missing formats from no JS runtime → deno default /
  `--js-runtimes node` opt-in, surfaced by the verifier as a warning;
  "outdated yt-dlp" is the diagnosis for most). Completes the acquire →
  process chain with ffmpeg-ops. Ships a §7 staleness
  verifier (`check-ytdlp-version.sh`: `--offline` structural in PR CI;
  `--live` = installed version >60 days behind the latest GitHub release,
  a documented core flag vanished from `yt-dlp --help`, or smoke-extraction
  failure → exit 10, network unreachable → exit 7 advisory; wired into
  `tests/check-resources.sh` + `freshness.yml`). 6 references, 1 date-stamped
  preset asset, 28-assertion offline self-test (age logic exercised via test
  seams - no network in tests).
- **`ffmpeg-ops` skill** - probe-first ffmpeg/ffprobe operations: ~30-command
  cookbook with footgun table (seek/keyframe semantics, `yuv420p`+`faststart`,
  quoting, VFR), EDL-driven editing (edit-as-code: schema asset +
  `cut-from-edl.py`, dry-run by default), `.cube` LUT grading with
  human-picks-the-grade chooser (`gen-luts.py`), STT/Whisper prep + the
  transcript-JSON contract, silence/scene segmentation (`detect-segments.py`),
  VMAF/SSIM quality gates (`quality-compare.py`), two-pass loudnorm automation,
  hw-encoder proof-encoding (`capability-scan.sh` - listed ≠ working), chapter
  authoring from scene/silence detection (`make-chapters.py` - ffmetadata mux /
  YouTube description / WebVTT), probe `--doctor` triage (each hazard - VFR,
  HDR transfer, rotation, interlacing, non-yuv420p, moov-at-EOF - paired with
  its exact fix command, exit 10), target-size compression
  (`smart-compress.py` - computed two-pass bitrate, auto audio/downscale,
  size-verified), scrub-preview sprites + WebVTT thumbnail track
  (`make-sprites.py`), an error-decoder reference (cryptic message → cause →
  fix), and a §7 staleness verifier (`verify-commands.sh`, wired into PR CI +
  freshness). Color grading is a first-class wing: a ~40-recipe look catalog
  (film stocks incl. CineStill halation as a verified composite, signature
  movie grades, era/genre moods, Sin City `colorhold`) with per-look scope
  checks and failure modes, an 18-variant mono/duo/tritone tone-map family
  (chroma = stop distance from the grey axis), the Hald-CLUT
  grade-anywhere→LUT workflow, a scope-matching ladder with its governing
  rule (transfer the chroma fingerprint globally; match key per scene-type,
  never the global mean) and a real-footage worked extraction (`grimdark`),
  plus a skin-tone equity caveat verified on the Kodak test portraits.
  `gen-luts.py` carries 32 parametric looks (channel-mix + 2/3-stop gradient
  maps). 19 references, 3 assets, 107-assertion self-test with
  lavfi-synthesized fixtures (no binary fixtures in repo).

### Fixed (media stack)
- **`ffmpeg-ops/cut-from-edl.py`** (found by real-media E2E):
  the output directory was created *after* ffmpeg opened the temp output, so
  any `-o` into a not-yet-existing directory died with a cryptic
  "Error opening output files"; and CLI `-o` resolved against the EDL's
  directory instead of the CWD (`-o work/final.mp4` with the EDL in `work/`
  silently meant `work/work/final.mp4`). `-o` is now CWD-relative (the EDL's
  own `output` field stays EDL-relative per the schema), and the destination
  dir is created before the concat runs.


### Added (skill resource protocol)
- **`docs/SKILL-RESOURCE-PROTOCOL.md`** - the build standard for skill `scripts/`,
  `assets/`, and `references/`: stream separation, semantic exit codes, `--help`
  with EXAMPLES, first-comment-block contract, `--json` envelopes, agent safety,
  the resource-scaffold checklist, and the **staleness-verifier pattern** (an
  `--offline` structural check that gates PR CI plus a `--live` drift check that
  runs scheduled, never blocking a PR on a network blip)
- Four verifier/scanner scripts built to the protocol:
  `claude-api-ops/check-model-table.py` (model+pricing table drift),
  `terraform-ops/check-action-refs.sh` (GitHub Action `uses:` refs resolve —
  catches the exact `trivy-action` tag bug from v3.0),
  `claude-code-ops/validate-hooks-json.py` (lint a hooks.json against the
  30-event catalog), `playwright-ops/triage-flakes.py` (rank flaky tests from a
  JSON report). Plus assets: `agentic-loop.py`, `output-schema.json`,
  `hooks.json.template`
- CI: `tests/check-resources.sh` runs the offline verifiers in PR CI;
  `.github/workflows/freshness.yml` runs the live drift checks weekly (advisory)

### Removed
- **20 expert agents** deprecated as part of the skills-first restructure
  (23 → 3 agents):
  - 11 language/framework experts → their `-ops` skill twins (python,
    typescript, javascript, go, rust, react, vue, astro, laravel, sql, postgres)
  - cypress-expert → `cypress-ops`; cloudflare-expert + wrangler-expert →
    `cloudflare-ops`; bash-expert → `bash-ops`; craftcms-expert → `craftcms-ops`;
    payloadcms-expert → `payloadcms-ops`; asus-router-expert → `asus-router-ops`
  - claude-architect → folded into `claude-code-ops`; aws-fargate-ecs-expert →
    folded into `container-orchestration`
  Per Anthropic's guidance, knowledge belongs in skills (progressive disclosure,
  single source of truth); subagents are reserved for context isolation. The
  only agents that remain are pure isolation/worker roles: `git-agent`,
  `firecrawl-expert`, `project-organizer`. Dispatching skills route
  `general-purpose` agents with skill preloading.
- `claude-code-debug`, `claude-code-headless`, `claude-code-hooks` skills -
  merged into `claude-code-ops` (content was written against Claude Code
  ~2.0; the stale `$TOOL_INPUT` hook contract is gone, stdin JSON is current)

### Added
- **`claude-api-ops` skill** - building ON Claude: Messages API, tool use,
  prompt caching, structured outputs (`output_config.format`), batches,
  extended thinking, model selection, Agent SDK (Python + TypeScript)
- **`playwright-ops` skill** - e2e testing: selector hierarchy, fixtures/POM,
  network mocking, auth storageState, CI sharding, flake hunting, config template
- **`terraform-ops` skill** - Terraform/OpenTofu IaC: state management,
  module patterns, OIDC CI/CD workflow template, drift detection, write-only
  secrets, native `terraform test`
- **`claude-code-ops` skill** - merges + refreshes claude-code-debug,
  claude-code-headless, claude-code-hooks against current docs: 30-event hook
  catalog with JSON contracts, current skill frontmatter spec, headless/CLI
  reference, extension debugging decision trees (+ extension-architecture from
  claude-architect)
- **`cypress-ops`, `cloudflare-ops`, `bash-ops` skills** - converted from the
  cypress/cloudflare/wrangler/bash agents and refreshed against current docs
  (Cypress `data-test`/Test Replay/cy.session; wrangler `deploy` not `publish`,
  jsonc config, Workers static assets; defensive bash to the resource protocol)
- **`craftcms-ops`, `payloadcms-ops`, `asus-router-ops` skills** - converted
  from the niche CMS/router agents and refreshed against current docs (Craft 5
  Matrix-as-entries; Payload 3 Next.js-native + Local API; Asuswrt-Merlin
  hardening + WireGuard)
- **Live security guard hooks**: `config-change-guard.sh` (ConfigChange event -
  scans edited Claude settings files for worm-persistence IOCs the moment
  they're written, reusing integrity-audit patterns) and `worktree-guard.sh`
  (PreToolUse - mechanically enforces `rules/worktree-boundaries.md`)
- **Plugin hook auto-wiring** (`hooks/hooks.json`) - plugin installs get the
  security-advisory hook set (pre-install-scan, manifest-dep-scan,
  session-start unicode scan, config-change guard, worktree guard) with zero
  hand-wiring; formatting/lint hooks stay opt-in examples
- **`fleet track`** command - register natively-spawned branches as fleet lanes
- New frontmatter on high-traffic skills: `when_to_use` (10 skills),
  `argument-hint` (iterate/review/testgen/explain), `effort: high`
  (iterate/review)
- README "Skill Description Budget" guidance - /doctor overflow check,
  `skillOverrides`, 1,536-char per-skill cap
- CI: doc-drift gate (`tests/doc-drift.sh`) - docs must match disk
- CI: skill behavioural test suites (`tests/run-skill-tests.sh`)

### Fixed
- `fleet.sh` `ensure_fleet_dir` returned 1 under `set -e` on every invocation
  after the first, silently killing post-init commands
- fleet-ops e2e suite asserted a worktree path `fleet.sh` no longer uses
  (now 29/29 against real behaviour)

### Changed
- **fleet-ops v2** - repositioned as landing discipline (queue, test gate,
  pre-land scrub, one-shot revert) on top of native agent teams / background
  agents, which now own the spawning half; no longer EXPERIMENTAL except the
  daemon
- **/save + /sync repositioned** - native auto-memory covers single-machine
  context; these commands' value is portable state: task restore,
  git-trackable, team-shareable, cross-machine
- supply-chain-defense description trimmed under the 1,536-char listing cap
- README/AGENTS.md/PLAN.md reconciled with actual inventory; ghost references
  removed (`rules/thinking.md`, `docs/DASH.md`)
- `tests/skills/functional/git-workflow.*` renamed to `git-cli-tools.*`

## [2.10.1] - 2026-05-29

### Fixed
- Plugin + marketplace manifests made valid against the official schema;
  `claude plugin validate` added as a CI gate (#4)

## [2.10.0] - 2026-05-25

### Added
- `prompt-injection-defense` skill - instruction-integrity defense: hidden-Unicode
  scanner (bidi/Trojan Source, tag-block smuggling, zero-width), byte-faithful
  sanitizer, SessionStart + git pre-commit hooks, `rules/prompt-injection.md`

## [2.9.0] - 2026-05-25

### Added
- `supply-chain-defense` skill - behavioural-first dependency security:
  Socket.dev integration (free CLI + zero-auth depscore MCP), exposure-check
  across 6 ecosystems + editor extensions, integrity-audit for worm persistence,
  7-day release cooldown, install + manifest advisory hooks,
  `rules/supply-chain.md`, 42-assertion offline test suite

## [2.8.0] - 2026-05-18

### Added
- `mac-ops` skill finalized - macOS workstation diagnostics, peer to
  `windows-ops`: 23 scripts + 11 references (TCC privacy, wake reasons,
  Spotlight, APFS storage pressure)

## [2.7.0] - [2.7.8] - 2026-05-17 to 2026-05-18

### Added
- `mac-ops` incremental build-up: kext/firewall/keychain/bluetooth/font audits,
  brew-health, sysdiagnose-helper, quickrun consolidator, worked examples

## [2.6.0] - 2026-05-15

### Added
- `windows-ops` skill - Windows workstation diagnostics: health-audit panel,
  crash-triage (Event 41 BugCheck decoding), recover-clone for dying drives

## [2.5.0] - 2026-05-14

### Added
- `net-ops` skill - cross-platform network troubleshooting ladder (link → app),
  IPv6 classifier, MTU/PMTU, DoH detection, `--watch`/`--json`/`--redact`
- `portless-ops` skill - local-dev HTTPS proxy operations for Vercel Labs portless
- `process-compose-ops` skill - Process Compose supervisor operations

### Fixed
- `summon` + `fleet-ops` registered in plugin manifest (were committed but unindexed)

### Removed
- `/canvas` command + `canvas-tui` package - experimental, Warp-specific, unused;
  removes the only npm runtime-dep surface

## [2.4.12] - 2026-05-05

### Fixed
- `install.sh` made cross-platform (Linux/macOS/Windows Git Bash)

## [2.4.11] - 2026-05-02

### Added
- `summon` skill - transfer Claude Desktop Code-tab sessions between accounts

## [2.4.10] - 2026-04-29

### Changed
- `github-ops` Recent Updates rule sharpened: features-not-bugs criteria

## [2.4.9] - 2026-04-26

### Added
- `git-ops` hygiene checks - status.sh flags feature-branch checkouts, stale merges
- `docs/references/claude-desktop-internals.md` - Desktop session architecture map

## [2.4.7] - 2026-04-26

### Fixed
- `push-gate` first-push to new remote (gitleaks scan branches on remote-ref existence)

## [2.4.6] - 2026-04-26

### Added
- `github-ops` skill - GitHub remote operations: repo creation, releases,
  metadata, README Recent Updates convention; three modes (new/update/audit)

## [2.4.5] - 2026-04-26

### Added
- `leveldb-ops` skill - read Chromium/Electron LevelDB stores via ccl_chromium_reader

## [2.4.4] - 2026-04-25

### Changed
- `/iterate` enhancements - Batch+bisect, Until/Stagnation stop conditions,
  branch isolation, `iterate/best` tag, always-summarize-on-exit

## [2.4.3] - 2026-04-24

### Added
- Worktree-aware `git-ops` (status.sh + worktree-survey.sh)
- `push-gate` skill - pre-push secret/forbidden-file gate, no bypass
- `rules/worktree-boundaries.md`

### Fixed
- `auto-skill` suggestions persisted to pending.log, surfaced at `/sync`

## [2.4.2] - 2026-04

### Changed
- Registered push-gate, auto-skill visibility fix

## [2.4.1] - 2026-04

### Added
- 8 daemon output styles (Atlas, Coach, Harbour, Meridian, Noir, Roast, Sage,
  Scout) - 13 total

## [2.4.0] - 2026-04

### Added
- `auto-skill` skill - self-learning skill creation via PostToolUse/Stop hooks
- `pigeon` skill (renamed from agentmail) - inter-session pmail, SQLite-backed

## [2.3.1] - 2026-04

### Added
- `genart-ops` skill (1,843 lines)

### Changed
- All skills migrated to the Agent Skills specification (agentskills.io)

## [2.3.0] - 2026-03

### Added
- Orchestrator-dispatch pattern: `git-ops` + `git-agent` (replaces
  `git-workflow`), `perf-ops`, `security-ops` parallel audits
- Skill preloading for dispatched agents; `model: sonnet` for expert dispatch

## [2.2.x] - 2026-03

### Changed
- `/introspect` Session Insights; `/setperms` 74 default permissions

### Removed
- `claude-code-templates` (redundant with first-party skill-creator)

## [2.1.0] - 2026-03

### Added
- `/iterate` skill - autonomous improvement loop (Karpathy autoresearch pattern)

## [2.0.0] - 2026-03

### Added
- 22 new `-ops` skills (React, Vue, Go, Rust, TypeScript, Docker, CI/CD,
  PostgreSQL, Nginx, Auth, Monitoring, Debug, MCP, Tailwind, and more)
- cc-session CLI, 3 hooks, 5 output styles

### Changed
- All 14 `-patterns` skills renamed to `-ops`

## [1.x] - 2025-11 to 2026-02

### Added
- Initial toolkit: session continuity (`/save` + `/sync`, schema v3.1), expert
  agents, Python skill family, tech-debt scanner, modern CLI toolkit, validation
  suite

[Unreleased]: https://github.com/0xDarkMatter/claude-mods/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.10.1...v3.0.0
[2.10.1]: https://github.com/0xDarkMatter/claude-mods/compare/v2.10.0...v2.10.1
[2.10.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.9.0...v2.10.0
[2.9.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.8.0...v2.9.0
[2.8.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.7.8...v2.8.0
[2.6.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.5.0...v2.6.0
[2.5.0]: https://github.com/0xDarkMatter/claude-mods/compare/v2.4.12...v2.5.0
