// Fixture suite for tests/run.sh. One strong test (pins the limit boundary) and one weak
// test (fee of zero only), so the harness can be seen both proving and failing to prove.
import { overLimit, fee } from "../src/limit.mjs";

const failures = [];
const check = (name, ok) => { if (!ok) failures.push(name); };

check("spending exactly the limit is allowed", overLimit(100, 100) === false);
check("one cent over the limit is refused", overLimit(100.01, 100) === true);
check("no fee on a zero amount", fee(0) === 0);

for (const f of failures) console.error(`FAIL ${f}`);
process.exit(failures.length ? 1 : 0);
