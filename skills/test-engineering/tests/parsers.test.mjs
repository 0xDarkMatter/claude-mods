// Adapter parsers against REAL runner reports (recorded from synthetic projects, machine
// paths stripped). Each check is named for the misclassification it prevents: the costly
// failure is a crash or a build error counted as a kill, which makes a gap look protected.
// Run by tests/run.sh; exit 0 all pass, 1 any failure.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { applyMutation, batchTrusted, classify, parseGoJson, parseJestJson, parseJunit, proveVerdict, scrubEnv } from "../scripts/mutate.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const fx = name => readFileSync(join(here, "fixtures", name), "utf8");
let failed = 0;
const check = (name, ok) => { console.log(`  ${ok ? "PASS" : "FAIL"}  ${name}`); if (!ok) failed++; };

const v = parseJestJson(fx("vitest.json"), "/repo");
check("vitest: an import crash is a suite error, not a kill", v.suiteErrors.length === 1 && v.suiteErrors[0].file === "broken.test.mjs");
check("vitest: the failing assertion is named, with its file", v.failedTests.length === 1 && v.failedTests[0].test === "keeps negative totals negative" && v.failedTests[0].file === "money.test.mjs");
check("vitest: total comes from the report, not from counting lines", v.total === 2);

const p = parseJunit(fx("pytest.xml"));
check("pytest: a skipped test counts toward the total but never as a failure", p.total === 3 && p.skipped === 1 && p.failed === 1);
check("pytest: the failing test is named classname::name", p.failedTests[0]?.test === "test_money::test_keeps_negative_totals_negative");

const pc = parseJunit(fx("pytest-collect-error.xml"));
check("pytest: a collection failure is a suite error, not a kill", pc.failed === 0 && pc.suiteErrors.length === 1);
check("pytest: a collection failure classifies as suite-error", classify({ parsed: true, ...pc, code: 2 }) === "suite-error");

const g = parseGoJson(fx("go.jsonl"));
check("go: a package that does not compile is a build failure", g.buildFails.length >= 1);
check("go: a build failure classifies as compile-error even beside a real kill", classify({ parsed: true, ...g, code: 1 }) === "compile-error");
check("go: the real failing test is still named", g.failedTests.some(t => t.test === "TestCentsRejectsNegative"));

check("classify: a kill in an incomplete run is still a kill", classify({ parsed: true, failed: 1, incomplete: true, code: 1 }) === "killed");
check("classify: a green but incomplete run is never a survivor", classify({ parsed: true, failed: 0, incomplete: true, code: 0 }) === "incomplete");
check("classify: green tests with a red typecheck are type-killed, not killed", classify({ parsed: true, failed: 0, code: 0, typecheckOk: false }) === "type-killed");

const killedByOther = proveVerdict({ status: "killed", killedBy: ["totals > rounds half up"] }, "refuses negative");
check("prove: a mutant killed only by OTHER tests does not prove the new one", killedByOther.proved === false && /killed-by-other/.test(killedByOther.verdict));
check("prove: a kill by the named test proves it (case-insensitive)", proveVerdict({ status: "killed", killedBy: ["money > Refuses Negative totals"] }, "refuses negative").proved === true);
check("prove: a survivor never proves anything", proveVerdict({ status: "survived", killedBy: [] }, "x", true).proved === false);
check("batch: a closing control with a different test count is untrusted", batchTrusted({ status: "green", total: 40 }, { status: "green", total: 39 }) === false);
check("batch: a red closing control is untrusted", batchTrusted({ status: "green", total: 40 }, { status: "killed", total: 40 }) === false);

const crlf = applyMutation("a > b;\r\nc\r\n", "a > b;", "a >= b;");
check("applyMutation: a CRLF file keeps CRLF after the edit", crlf.ok && crlf.mutated === "a >= b;\r\nc\r\n");
check("applyMutation: an anchor that occurs twice is refused", applyMutation("x\nx\n", "x", "y").ok === false);

const s = scrubEnv({ PATH: "/bin", STRIPE_API_KEY: "k", GITHUB_TOKEN: "t", GIT_AUTHOR_NAME: "n", DATABASE_URL: "u", DEPLOY_KEY: "d" }, ["DATABASE_URL"]);
check("scrubEnv: credentials are removed by name", !("STRIPE_API_KEY" in s.env) && !("GITHUB_TOKEN" in s.env) && !("DEPLOY_KEY" in s.env));
check("scrubEnv: lookalike names survive and keepEnv opts back in", s.env.GIT_AUTHOR_NAME === "n" && s.env.DATABASE_URL === "u" && s.env.PATH === "/bin");

console.log(failed ? `${failed} parser check(s) failed` : "all parser checks passed");
process.exit(failed ? 1 : 0);
