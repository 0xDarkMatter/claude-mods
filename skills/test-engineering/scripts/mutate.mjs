#!/usr/bin/env node
// Plant one mutant at a time and record which tests catch it: prove-it-fails and audits.
//
// Usage:   mutate.mjs (--config <cfg.json> | --runner <name>) [MODE] [OPTIONS] [-- runner args]
// Input:   a catalogue (--catalogue): JSON array of mutant rows, shape in assets/mutant.example.json;
//          cfg.json: {runner, repo, args, command, python, typecheck, timeoutS, keepEnv}
// Output:  stdout: ONE JSON summary {mode, runner, baseline, closing, trusted, proved, counts,
//          rows, scrubbedEnv, network}; --out also appends one JSONL line per result row
// Stderr:  progress, warnings, the crash-backup path, errors
// Exit:    0 ok (--prove: the named test went red), 1 harness error (incl. a failed restore),
//          2 usage, 3 not found, 4 invalid catalogue (anchor missing or not unique),
//          5 precondition (baseline red or incomplete, typecheck red before mutation,
//          runner missing), 10 finding (--prove: not proved; batch: a closing null control
//          disagreed with the baseline, so the batch is untrusted)
//
// Examples:
//   mutate.mjs --runner vitest --baseline
//   mutate.mjs --runner vitest --catalogue m.json --dry-run
//   mutate.mjs --runner vitest --catalogue m.json --prove "refuses a used reset link" -- test/reset.test.ts
//   mutate.mjs --runner pytest --catalogue m.json --prove test_rejects_negative_total -- tests/test_money.py
//   mutate.mjs --runner command --catalogue m.json --prove x -- node --test test/x.test.mjs
//   mutate.mjs --config .mutate.json --catalogue audit.json --out results.jsonl
//
// Contract and invariants (references/audit.md and references/write.md own the reasoning):
// - Runs in a LIVE working tree (write mode) as well as disposable copies (audits), so it
//   never calls `git checkout`: the mutated file is restored from the bytes read before the
//   edit, re-read to verify, and a crash backup is kept in the OS temp dir until then. A
//   `git checkout` here would also discard the developer's uncommitted fix.
// - A green run only counts when every test ran: the baseline's test count is the expected
//   total, and a non-killing run below it is retried, then classified `incomplete`.
// - Only `killed` means a test caught the mutant. compile-error and type-killed are mutation
//   form problems; suite-error is a red for the wrong reason (import or collection crash).
// - Secret-looking env vars are stripped from every test run (keepEnv opts one back in), so a
//   mutant that disables a dry-run guard cannot reach production with live credentials. This
//   does NOT deny network; unattended runs belong in a network-less container (audit.md).
// - Zero dependencies; Node >= 18. Adapters parse machine reports, never human stdout.
import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HELP = `mutate.mjs - plant one mutant at a time and record which tests catch it.

Usage:
  mutate.mjs (--config <cfg.json> | --runner <name>) [MODE] [OPTIONS] [-- runner args]

Modes (default: run the whole catalogue as an audit batch):
  --baseline           run the unmutated suite once; exit 5 unless it is green and complete
  --dry-run            check every anchor exists exactly once; run nothing
  --prove <name>       catalogue of ONE mutant; exit 0 only if a failing test's name or
                       file contains <name> (write mode's prove-it-fails)

Options:
  --catalogue <file>   JSON array of {id, file, old, new, bug, class} rows
  --runner <name>      vitest | jest | pytest | go | command
  --repo <dir>         repository root (default: current directory)
  --out <file>         also append one JSONL row per result
  --only <ID,ID>       run only these catalogue ids
  --expect-total <n>   expected test count (default: measured by the baseline run)
  --retries <n>        re-runs of an incomplete non-killing run (default 2)
  --timeout <s>        per-run timeout in seconds (default 900)
  --typecheck "<cmd>"  typecheck command, run before mutating and on every survivor
  --keep-env <A,B>     secret-looking env vars to pass to the tests anyway
  -h, --help           this text

After "--": extra runner args (vitest/jest/pytest/go), or the whole command (runner command).

Exit: 0 ok, 1 harness error, 2 usage, 3 not found, 4 invalid catalogue, 5 precondition,
      10 finding (prove: not proved; batch: untrusted).

Examples:
  mutate.mjs --runner vitest --baseline
  mutate.mjs --runner vitest --catalogue m.json --prove "refuses a used reset link" -- test/reset.test.ts
  mutate.mjs --runner pytest --catalogue m.json --prove test_rejects_negative_total
  mutate.mjs --runner command --catalogue m.json --prove x -- node --test test/x.test.mjs
  mutate.mjs --config .mutate.json --catalogue audit.json --out results.jsonl
`;

// ============================== pure helpers (exported for tests) ==============================

const posix = p => p.split(sep).join("/").replace(/\\/g, "/");

// Names, never values. AUTH only as a whole segment so GIT_AUTHOR_NAME survives.
const SECRET_NAME = /(SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|CREDENTIAL|COOKIE|WEBHOOK|DATABASE_URL|CONNECTION_STRING|(^|_)O?AUTH(_|$)|(^|_)KEY$|_DSN$)/i;
export function scrubEnv(env, keep = []) {
  const keepSet = new Set(keep.map(k => k.toUpperCase()));
  const out = {}, scrubbed = [];
  for (const [k, v] of Object.entries(env)) {
    if (SECRET_NAME.test(k) && !keepSet.has(k.toUpperCase())) scrubbed.push(k);
    else out[k] = v;
  }
  return { env: out, scrubbed: scrubbed.sort() };
}

// Anchors match after CRLF normalisation; the file keeps its own line endings.
export function applyMutation(original, oldText, newText) {
  const eol = original.includes("\r\n") ? "\r\n" : "\n";
  const lf = original.replace(/\r\n/g, "\n");
  const n = lf.split(oldText).length - 1;
  if (n !== 1) return { ok: false, occurrences: n };
  const mutated = lf.replace(oldText, () => newText).replace(/\n/g, eol);
  return { ok: mutated !== original, occurrences: 1, mutated };
}

// Only `killed` means a test caught it. Order matters: a failing test outranks an
// incomplete run (a kill is a kill), but a build failure outranks everything after a timeout.
export function classify(s) {
  if (s.timedOut) return "timeout";
  if (!s.parsed) return "no-report";
  if (s.buildFails?.length) return "compile-error";
  if (s.failed > 0) return "killed";
  if (s.suiteErrors?.length) return "suite-error";
  if (s.incomplete) return "incomplete";
  if (s.code !== 0) return "errors-row";
  if (s.typecheckOk === false) return "type-killed";
  return "survived";
}

// Write mode's verdict. A kill only proves THIS test if the named test is among the red ones;
// otherwise other tests caught the mutant and the new test is unproven. A countless runner
// (`command`) has no names, so its command must run only the test being proved.
export function proveVerdict(row, name, countless = false) {
  const needle = String(name).toLowerCase();
  const byName = countless || row.killedBy.some(t => t.toLowerCase().includes(needle));
  const proved = row.status === "killed" && byName;
  return { proved, nameChecked: !countless, ...(row.status === "killed" && !byName ? { verdict: "killed-by-other: the named test stayed green; other tests caught this mutant" } : {}) };
}

// The closing null control re-runs the unmutated suite. A different verdict OR a different
// test count means the environment drifted mid-batch (a corrupted toolchain once turned a
// no-op mutant into a "kill"), so none of the batch's rows can be believed.
export function batchTrusted(baseline, closing) {
  return closing.status === "green" && closing.total === baseline.total;
}

// vitest's JSON reporter writes jest's format, so one parser serves both.
export function parseJestJson(text, repo = ".") {
  const r = JSON.parse(text);
  const failedTests = [], suiteErrors = [];
  for (const f of r.testResults ?? []) {
    const file = posix(relative(repo, f.name ?? ""));
    const failing = (f.assertionResults ?? []).filter(a => a.status === "failed");
    for (const a of failing) failedTests.push({ file, test: a.fullName ?? a.title, msg: firstLine(a.failureMessages?.[0]) });
    if (f.status === "failed" && failing.length === 0) suiteErrors.push({ file, msg: firstLine(f.message) });
  }
  return { parsed: true, total: r.numTotalTests, failed: r.numFailedTests, skipped: (r.numPendingTests ?? 0) + (r.numTodoTests ?? 0), failedTests, suiteErrors };
}

// pytest --junitxml with junit_family=xunit1 (carries the file attribute).
export function parseJunit(xml) {
  const unesc = s => s.replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&apos;/g, "'").replace(/&#10;/g, " ").replace(/&amp;/g, "&");
  const attr = (tag, k) => { const m = tag.match(new RegExp(`\\s${k}="([^"]*)"`)); return m ? unesc(m[1]) : ""; };
  const failedTests = [], suiteErrors = [];
  let total = 0, failed = 0, skipped = 0;
  const re = /<testcase\b([^>]*?)(\/>|>([\s\S]*?)<\/testcase>)/g;
  let m;
  while ((m = re.exec(xml))) {
    const head = m[1], body = m[3] ?? "";
    const file = attr(head, "file") || attr(head, "classname").replace(/\./g, "/") + ".py";
    const fail = body.match(/<failure\b([^>]*)/), err = body.match(/<error\b([^>]*)/);
    // A collection error is reported as a testcase NAMED after the module, with an empty
    // classname and <error message="collection failure">: an import crash, never a kill.
    if (err && (!attr(head, "classname") || !attr(head, "name") || /collection failure/i.test(attr(err[0], "message")))) {
      suiteErrors.push({ file, msg: attr(err[0], "message").slice(0, 240) }); continue;
    }
    total++;
    if (/<skipped\b/.test(body)) { skipped++; continue; }
    if (fail || err) {
      failed++;
      failedTests.push({ file, test: `${attr(head, "classname")}::${attr(head, "name")}`, msg: attr((fail ?? err)[0], "message").slice(0, 240) });
    }
  }
  if (/<testsuite\b[^>]*\berrors="[1-9]/.test(xml) && total === 0 && !suiteErrors.length) suiteErrors.push({ file: "?", msg: "collection error with no testcase" });
  return { parsed: true, total, failed, skipped, failedTests, suiteErrors };
}

// `go test -json`. A package that fails with no failing test and no build failure crashed
// (TestMain or init panic, timeout); a build failure is a compile-error, never a kill.
export function parseGoJson(text, testFileIndex = {}) {
  if (!text.trim()) return { parsed: false };
  const failedTests = [], buildFails = new Set(), pkgFail = new Set(), pkgWithTestFail = new Set();
  let total = 0, failed = 0, skipped = 0;
  for (const line of text.split("\n")) {
    if (!line.startsWith("{")) continue;
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (e.Action === "build-fail") buildFails.add(e.ImportPath ?? e.Package);
    if (e.FailedBuild) buildFails.add(e.Package);
    if (e.Action === "output" && !e.Test && /\[build failed\]|\[setup failed\]/.test(e.Output ?? "")) buildFails.add(e.Package);
    if (!e.Test) { if (e.Action === "fail" && e.Package) pkgFail.add(e.Package); continue; }
    if (!["pass", "fail", "skip"].includes(e.Action)) continue;
    total++;
    if (e.Action === "skip") skipped++;
    if (e.Action === "fail") {
      failed++;
      pkgWithTestFail.add(e.Package);
      failedTests.push({ file: testFileIndex[`${e.Package}::${e.Test.split("/")[0]}`] ?? e.Package, test: e.Test, msg: "" });
    }
  }
  const suiteErrors = [...pkgFail].filter(p => !pkgWithTestFail.has(p) && !buildFails.has(p)).map(p => ({ file: p, msg: "package failed with no failing test" }));
  return { parsed: true, total, failed, skipped, failedTests, suiteErrors, buildFails: [...buildFails] };
}

const firstLine = s => String(s ?? "").split("\n")[0].slice(0, 240);

// ================================== process plumbing ==================================

function parseArgs(argv) {
  const VALUE = new Set(["config", "catalogue", "runner", "repo", "out", "only", "prove", "expect-total", "retries", "timeout", "typecheck", "keep-env"]);
  const FLAG = new Set(["baseline", "dry-run", "help", "h"]);
  const a = { rest: [] };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === "--") { a.rest = argv.slice(i + 1); break; }
    const k = t.replace(/^--?/, "");
    if (t.startsWith("-") && FLAG.has(k)) { a[k] = true; continue; }
    if (t.startsWith("--") && VALUE.has(k)) {
      if (i + 1 >= argv.length) throw usage(`--${k} needs a value`);
      a[k] = argv[++i]; continue;
    }
    throw usage(`unknown argument: ${t}`);
  }
  return a;
}
const usage = msg => Object.assign(new Error(msg), { exit: 2 });
const fail = (exit, msg) => Object.assign(new Error(msg), { exit });

function killTree(pid) {
  if (process.platform === "win32") spawnSync("taskkill", ["/pid", String(pid), "/T", "/F"]);
  else try { process.kill(-pid, "SIGKILL"); } catch { /* already gone */ }
}

// .cmd/.bat shims (npm, npx) cannot be spawned without a shell on Windows; quote by hand.
function needsShell(cmd) {
  return process.platform === "win32" && !/[\\/]/.test(cmd) && !/^(node|go|python3?|py)(\.exe)?$/i.test(cmd);
}
const winQuote = s => (/[\s"&|<>^]/.test(s) ? `"${s.replace(/"/g, '\\"')}"` : s);

function run(cmd, args, { cwd, env, timeoutMs, keepStdout }) {
  return new Promise(res => {
    const started = Date.now();
    const shell = needsShell(cmd);
    let child;
    try {
      child = spawn(shell ? [cmd, ...args].map(winQuote).join(" ") : cmd, shell ? [] : args,
        { cwd, env, shell, stdio: ["ignore", "pipe", "pipe"], detached: process.platform !== "win32" });
    } catch (e) { return res({ code: -1, spawnError: e.message, ms: 0, tail: e.message, out: "" }); }
    let tail = "", out = "", timedOut = false;
    child.stdout.on("data", d => { const s = d.toString(); tail = (tail + s).slice(-4000); if (keepStdout) out += s; });
    child.stderr.on("data", d => { tail = (tail + d.toString()).slice(-4000); });
    child.on("error", e => { tail += `\n${e.message}`; });
    const timer = setTimeout(() => { timedOut = true; killTree(child.pid); }, timeoutMs);
    child.on("close", code => { clearTimeout(timer); res({ code, timedOut, ms: Date.now() - started, tail, out }); });
  });
}

function goTestIndex(repo) {
  const idx = {};
  const modFile = join(repo, "go.mod");
  if (!existsSync(modFile)) return idx;
  const mod = (readFileSync(modFile, "utf8").match(/^module\s+(\S+)/m) ?? [])[1];
  const walk = d => {
    for (const n of readdirSync(d)) {
      const p = join(d, n);
      if (statSync(p).isDirectory()) { if (!/^(\.git|vendor|testdata|node_modules)$/.test(n)) walk(p); continue; }
      if (!n.endsWith("_test.go")) continue;
      const rel = posix(relative(repo, p)), dir = rel.split("/").slice(0, -1).join("/");
      const pkg = dir ? `${mod}/${dir}` : mod;
      for (const m of readFileSync(p, "utf8").matchAll(/^func (Test\w+)\(/gm)) idx[`${pkg}::${m[1]}`] = rel;
    }
  };
  walk(repo);
  return idx;
}

function pythonFor(cfg, repo) {
  if (cfg.python) return cfg.python;
  const venv = join(repo, ".venv", process.platform === "win32" ? "Scripts/python.exe" : "bin/python");
  return existsSync(venv) ? venv : process.platform === "win32" ? "python" : "python3";
}

function makeAdapter(cfg, repo) {
  const args = cfg.args ?? [];
  const jsBin = (pkg, entry) => {
    const p = join(repo, "node_modules", pkg, entry);
    if (!existsSync(p)) throw fail(5, `${pkg} not found at ${p} (install dependencies from the lockfile first)`);
    return p;
  };
  switch (cfg.runner) {
    case "vitest": case "jest": {
      const entry = cfg.runner === "vitest" ? jsBin("vitest", "vitest.mjs") : jsBin("jest", "bin/jest.js");
      return {
        command: report => [process.execPath, cfg.runner === "vitest"
          ? [entry, "run", ...args, "--reporter=json", `--outputFile=${report}`]
          : [entry, ...args, "--json", `--outputFile=${report}`]],
        parse: (report) => existsSync(report) ? parseJestJson(readFileSync(report, "utf8"), repo) : { parsed: false },
      };
    }
    case "pytest":
      return {
        command: report => [pythonFor(cfg, repo), ["-m", "pytest", ...args, `--junitxml=${report}`, "-o", "junit_family=xunit1"]],
        parse: report => existsSync(report) ? parseJunit(readFileSync(report, "utf8")) : { parsed: false },
      };
    case "go": {
      let idx;
      return {
        command: () => ["go", ["test", "-json", "-count=1", ...(args.length ? args : ["./..."])]],
        keepStdout: true,
        parse: (_r, res) => parseGoJson(res.out, idx ??= goTestIndex(repo)),
      };
    }
    case "command": {
      const cmd = cfg.command ?? args;
      if (!cmd.length) throw usage("runner command needs the command after --");
      // No machine report: red = non-zero exit, no test count, no test names.
      return {
        command: () => [cmd[0], cmd.slice(1)],
        parse: (_r, res) => res.spawnError ? { parsed: false } : { parsed: true, total: null, failed: res.code === 0 ? 0 : 1, skipped: 0, failedTests: [], suiteErrors: [], countless: true },
      };
    }
    default: throw usage(`unknown runner: ${cfg.runner} (vitest | jest | pytest | go | command)`);
  }
}

// ======================================== main ========================================

async function main() {
  let a;
  try { a = parseArgs(process.argv.slice(2)); } catch (e) { process.stderr.write(`mutate.mjs: ${e.message}\n`); return 2; }
  if (a.help || a.h) { process.stdout.write(HELP); return 0; }

  let cfg = {};
  if (a.config) {
    if (!existsSync(a.config)) throw fail(3, `config not found: ${a.config}`);
    cfg = JSON.parse(readFileSync(a.config, "utf8"));
  }
  if (a.runner) cfg.runner = a.runner;
  if (a.rest.length) cfg.args = a.rest;
  if (a.typecheck) cfg.typecheck = a.typecheck.split(" ").filter(Boolean);
  if (!cfg.runner) throw usage("--config or --runner is required");
  const repo = resolve(a.repo ?? cfg.repo ?? ".");
  if (!existsSync(repo)) throw fail(3, `repo not found: ${repo}`);
  const timeoutMs = Number(a.timeout ?? cfg.timeoutS ?? 900) * 1000;
  const retries = Number(a.retries ?? 2);
  const keep = [...(cfg.keepEnv ?? []), ...String(a["keep-env"] ?? "").split(",").filter(Boolean)];
  const { env, scrubbed } = scrubEnv(process.env, keep);

  const mode = a.baseline ? "baseline" : a["dry-run"] ? "dry-run" : a.prove !== undefined ? "prove" : "batch";
  let catalogue = [];
  if (mode !== "baseline") {
    if (!a.catalogue) throw usage(`--catalogue is required for ${mode}`);
    if (!existsSync(a.catalogue)) throw fail(3, `catalogue not found: ${a.catalogue}`);
    const raw = JSON.parse(readFileSync(a.catalogue, "utf8"));
    catalogue = Array.isArray(raw) ? raw : [raw];
    if (a.only) { const ids = new Set(a.only.split(",")); catalogue = catalogue.filter(m => ids.has(m.id)); }
    if (mode === "prove" && catalogue.length !== 1) throw usage(`--prove takes exactly one mutant, catalogue has ${catalogue.length}`);
    let bad = 0;
    for (const m of catalogue) {
      const p = join(repo, m.file ?? "");
      if (!m.file || !existsSync(p)) { process.stderr.write(`[${m.id}] file not found: ${m.file}\n`); bad++; continue; }
      if (m.old === m.new) { process.stderr.write(`[${m.id}] old === new\n`); bad++; continue; }
      const r = applyMutation(readFileSync(p, "utf8"), m.old, m.new);
      if (!r.ok) { process.stderr.write(`[${m.id}] anchor occurs ${r.occurrences}x in ${m.file} (must be exactly 1)\n`); bad++; }
    }
    if (bad) throw fail(4, `${bad} invalid catalogue row(s); fix the anchors first`);
    if (mode === "dry-run") { emit({ mode, runner: cfg.runner, anchors: catalogue.length, ok: true }); return 0; }
  }

  const tmp = mkdtempSync(join(tmpdir(), "mutate-"));
  let keepTmp = false;                                       // set when a backup is still needed
  try {
    const adapter = makeAdapter(cfg, repo);
    const gitStatus = () => {
      const r = spawnSync("git", ["-C", repo, "status", "--porcelain", "--untracked-files=no"], { encoding: "utf8" });
      return r.status === 0 ? r.stdout : null;
    };
    let n = 0;
    const runSuite = async () => {
      const report = join(tmp, `report-${n++}.${cfg.runner === "pytest" ? "xml" : "json"}`);
      const [cmd, cmdArgs] = adapter.command(report);
      const res = await run(cmd, cmdArgs, { cwd: repo, env, timeoutMs, keepStdout: adapter.keepStdout });
      const s = adapter.parse(report, res);
      return { res, s };
    };
    const typecheck = async () => {
      if (!cfg.typecheck) return undefined;
      const tc = await run(cfg.typecheck[0], cfg.typecheck.slice(1), { cwd: repo, env, timeoutMs: 600_000 });
      return { ok: tc.code === 0, ms: tc.ms, tail: tc.code === 0 ? "" : tc.tail.slice(-600) };
    };
    const runStatus = (s, res) => { const c = classify({ ...s, timedOut: res.timedOut, code: res.code }); return c === "survived" ? "green" : c; };
    const summarise = ({ res, s }) => ({ status: runStatus(s, res), total: s.total ?? null, failed: s.failed ?? null, skipped: s.skipped ?? null, exit: res.code, ms: res.ms, ...(s.parsed && !s.failed && !s.suiteErrors?.length && res.code === 0 ? {} : { tail: res.tail.slice(-1500) }) });

    if (scrubbed.length) process.stderr.write(`scrubbed ${scrubbed.length} secret-looking env var(s) from test runs: ${scrubbed.join(", ")}\n`);
    process.stderr.write("network is NOT denied by this harness; run unattended batches in a network-less container\n");
    // Opening null control: the unmutated suite must be green and complete, or no verdict means anything.
    process.stderr.write("baseline (unmutated) ... ");
    const base = await runSuite();
    const baseline = summarise(base);
    process.stderr.write(`${baseline.status} (total ${baseline.total ?? "?"}, ${Math.round(baseline.ms / 1000)}s)\n`);
    if (baseline.status !== "green") {
      emit({ mode, runner: cfg.runner, baseline, scrubbedEnv: scrubbed, network: "not-denied" });
      throw fail(5, `baseline is ${baseline.status}, not green: fix the suite (or --keep-env a variable it needs) before mutating`);
    }
    const tc0 = await typecheck();
    if (tc0 && !tc0.ok) throw fail(5, `typecheck is red before any mutation (pre-existing errors or a corrupt toolchain):\n${tc0.tail}`);
    if (mode === "baseline") { emit({ mode, runner: cfg.runner, baseline, scrubbedEnv: scrubbed, network: "not-denied" }); return 0; }

    const expectTotal = Number(a["expect-total"] ?? base.s.total ?? 0);
    const statusBefore = gitStatus();
    const rows = [];
    for (const m of catalogue) rows.push(await runMutant(m));

    async function runMutant(m) {
      const path = join(repo, m.file);
      const original = readFileSync(path);                      // bytes, restored verbatim
      const { mutated } = applyMutation(original.toString("utf8"), m.old, m.new);
      const backup = join(tmp, `${m.id}-${basename(m.file)}.orig`);
      writeFileSync(backup, original);
      const restore = () => writeFileSync(path, original);
      const onSignal = () => { restore(); process.stderr.write(`\ninterrupted: restored ${m.file}\n`); process.exit(130); };
      process.once("SIGINT", onSignal); process.once("SIGTERM", onSignal);
      process.stderr.write(`[${m.id}] ${m.file} (backup: ${backup}) ... `);
      let r, attempts = 0, tcm;
      try {
        writeFileSync(path, mutated);
        // GUARD: a runner can silently drop a test file and still report success, so a
        // non-killing run below the expected count is retried before it may be believed.
        do { attempts++; r = await runSuite(); }
        while (!r.res.timedOut && r.s.parsed && !r.s.failed && !r.s.buildFails?.length && expectTotal > 0 && r.s.total < expectTotal && attempts <= retries);
        r.s.incomplete = expectTotal > 0 && r.s.parsed && r.s.total != null && r.s.total < expectTotal;
        const green = runStatus(r.s, r.res) === "green";
        if (green) tcm = await typecheck();
      } finally {
        restore();
        process.removeListener("SIGINT", onSignal); process.removeListener("SIGTERM", onSignal);
      }
      if (!readFileSync(path).equals(original)) { keepTmp = true; throw fail(1, `RESTORE FAILED for ${m.file}; the original bytes are at ${backup}`); }
      rmSync(backup, { force: true });
      const after = gitStatus();
      if (statusBefore !== null && after !== statusBefore) throw fail(1, `tests changed tracked files while ${m.id} ran (snapshots or fixtures rewritten?); stopping. git status now:\n${after}`);
      const status = classify({ ...r.s, timedOut: r.res.timedOut, code: r.res.code, typecheckOk: tcm?.ok });
      const row = {
        id: m.id, file: m.file, bug: m.bug, class: m.class, status,
        killedBy: status === "killed" ? r.s.failedTests.slice(0, 40).map(t => t.test) : [],
        firstFailure: status === "killed" ? r.s.failedTests[0]?.msg : undefined,
        total: r.s.total ?? null, expectTotal: expectTotal || null, attempts, ms: r.res.ms,
        ...(tcm ? { typecheck: tcm } : {}),
        ...(["no-report", "errors-row", "compile-error", "suite-error", "timeout", "incomplete"].includes(status) ? { tail: r.res.tail.slice(-1500), suiteErrors: r.s.suiteErrors } : {}),
        ...(r.s.countless ? { countless: true } : {}),
      };
      if (a.out) appendFileSync(a.out, JSON.stringify(row) + "\n");
      process.stderr.write(`${status} (${Math.round(r.res.ms / 1000)}s)\n`);
      return row;
    }

    const counts = {};
    for (const r of rows) counts[r.status] = (counts[r.status] ?? 0) + 1;

    if (mode === "prove") {
      const row = rows[0];
      Object.assign(row, proveVerdict(row, a.prove, base.s.countless));
      emit({ mode, runner: cfg.runner, baseline, proved: row.proved, nameChecked: !base.s.countless, counts, rows, scrubbedEnv: scrubbed, network: "not-denied" });
      return row.proved ? 0 : 10;
    }

    // Closing null control: the same unmutated suite again. A different verdict or count
    // means the environment drifted mid-batch (the corrupt-binary failure), so no row is trusted.
    process.stderr.write("closing null control ... ");
    const closing = summarise(await runSuite());
    process.stderr.write(`${closing.status} (total ${closing.total ?? "?"})\n`);
    const trusted = batchTrusted(baseline, closing);
    emit({ mode, runner: cfg.runner, baseline, closing, trusted, counts, rows, scrubbedEnv: scrubbed, network: "not-denied" });
    return trusted ? 0 : 10;
  } finally {
    if (!keepTmp) rmSync(tmp, { recursive: true, force: true });
  }
}

function emit(obj) { process.stdout.write(JSON.stringify(obj, null, 2) + "\n"); }

const invokedDirectly = process.argv[1] && resolve(process.argv[1]).toLowerCase() === fileURLToPath(import.meta.url).toLowerCase();
if (invokedDirectly) {
  main().then(code => { process.exitCode = code; }, e => {
    process.stderr.write(`mutate.mjs: ${e.message}\n`);
    process.exitCode = e.exit ?? 1;
  });
}
