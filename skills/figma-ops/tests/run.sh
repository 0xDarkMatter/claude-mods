#!/usr/bin/env bash
# Self-test for figma-ops.
#
# Offline-deterministic (no Figma, no network). Exercises scripts/plan-layout.mjs
# against the shipped fixture and asserts the documented exit codes, output shape,
# and the geometric invariants the SKILL.md promises (true aspect ratio preserved,
# every image inside the canvas margin, overlap budget honoured, grid has no
# overlaps at all). Resolves paths relative to itself so it works in the repo and
# once installed to ~/.claude/skills/figma-ops/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass (or skipped: no node), 1 one or more failures
#
# Canvas behaviour (upload_assets, use_figma) cannot be tested offline; those rules
# are enforced by the SKILL.md gates, not by this suite.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
PLAN="$SKILL/scripts/plan-layout.mjs"
FIX="$SKILL/assets/plus-layout.example.json"

if ! command -v node >/dev/null 2>&1; then
  echo "figma-ops self-test: node not found — skipping (exit 0)"; exit 0
fi

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }

echo "=== figma-ops self-test ==="

# ── contract: --help, usage, bad input ───────────────────────────────────────
node "$PLAN" --help >/dev/null 2>&1;                       expect_exit "--help" 0 $?
node "$PLAN" >/dev/null 2>&1;                              expect_exit "no --input is usage error" 2 $?
node "$PLAN" --input "$FIX" --mode sideways >/dev/null 2>&1; expect_exit "unknown mode is usage error" 2 $?
node "$PLAN" --input /nonexistent.json >/dev/null 2>&1;    expect_exit "missing file is bad input" 3 $?
echo '{"images":[{"id":"x","w":100}]}' | node "$PLAN" --input - >/dev/null 2>&1; expect_exit "missing h is bad input" 3 $?
echo '{"images":[{"id":"x","w":100,"h":50,"arm":"Q"}]}' | node "$PLAN" --input - >/dev/null 2>&1; expect_exit "unknown arm is bad input" 3 $?

# stdout must be data-only: JSON parses even when stderr has diagnostics
OUT="$(node "$PLAN" --input "$FIX" --mode loose --json 2>/dev/null)"; RC=$?
expect_exit "loose plan on fixture" 0 $RC
node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' <<<"$OUT" >/dev/null 2>&1 && ok "stdout is valid JSON" || no "stdout is not valid JSON"

# ── invariants via a small node checker ──────────────────────────────────────
check() { # $1 = mode, $2 = expected exit
  local mode="$1" want="$2" json rc
  json="$(node "$PLAN" --input "$FIX" --mode "$mode" --json 2>/dev/null)"; rc=$?
  expect_exit "mode $mode exit code" "$want" "$rc"
  # Checker is a separate file: a `node -` heredoc cannot also take the plan on
  # stdin (the second redirection wins and node executes the JSON as a script).
  node "$HERE/check-invariants.mjs" "$mode" "$FIX" <<<"$json"
  [[ $? -eq 0 ]] && ok "mode $mode invariants" || no "mode $mode invariants"
}
check loose 0
check plus 0
check grid 0

# ── budget breach surfaces as exit 10 (still emits output) ───────────────────
node "$PLAN" --input "$FIX" --mode loose --tuck 400 --budget 10x10 --json >/dev/null 2>&1
expect_exit "over-budget overlap exits 10" 10 $?

# ── stage-assets.mjs ──────────────────────────────────────────────────────────
STAGE="$SKILL/scripts/stage-assets.mjs"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
# Git Bash mktemp returns /tmp/..., which node on Windows resolves against the current
# drive (wrong). cygpath -m yields C:/... which both bash and node accept.
command -v cygpath >/dev/null 2>&1 && SB="$(cygpath -m "$SB")"
mkdir -p "$SB/src/shotcraft_example.com/macbook" "$SB/out"
# Synthetic fixtures: a real 3x2 PNG (zlib via node), a JPEG that is only SOI+SOF0
# (the dimension reader walks markers, it never decodes pixels), and a GIF header.
node - "$SB/src" <<'EOF'
const fs = require('fs'), zlib = require('zlib'), path = require('path');
const dir = process.argv[2];
function crc(buf){let c=~0;for(const b of buf){c^=b;for(let k=0;k<8;k++)c=(c>>>1)^(0xEDB88320&-(c&1));}return ~c>>>0;}
function chunk(t,d){const len=Buffer.alloc(4);len.writeUInt32BE(d.length);const td=Buffer.concat([Buffer.from(t),d]);const c=Buffer.alloc(4);c.writeUInt32BE(crc(td));return Buffer.concat([len,td,c]);}
function png(w,h){const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(w,0);ihdr.writeUInt32BE(h,4);ihdr[8]=8;ihdr[9]=2;const raw=Buffer.alloc((1+w*3)*h);return Buffer.concat([Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]),chunk('IHDR',ihdr),chunk('IDAT',zlib.deflateSync(raw)),chunk('IEND',Buffer.alloc(0))]);}
function jpg(w,h){const sof=Buffer.alloc(19);sof[0]=0xFF;sof[1]=0xC0;sof.writeUInt16BE(17,2);sof[4]=8;sof.writeUInt16BE(h,5);sof.writeUInt16BE(w,7);sof[9]=3;return Buffer.concat([Buffer.from([0xFF,0xD8]),sof,Buffer.from([0xFF,0xD9])]);}
function gif(w,h){const b=Buffer.alloc(13);b.write('GIF89a',0,'ascii');b.writeUInt16LE(w,6);b.writeUInt16LE(h,8);return b;}
fs.writeFileSync(path.join(dir,'shotcraft_example.com/macbook/abc123-example-macbook-sectn-02-hero--section.png'), png(3,2));
fs.writeFileSync(path.join(dir,'IMG_0001.JPG'), jpg(40,30));
fs.writeFileSync(path.join(dir,'brand-sheet.gif'), gif(8,4));
fs.writeFileSync(path.join(dir,'broken.png'), Buffer.from('not a png'));
EOF

node "$STAGE" --help >/dev/null 2>&1;                       expect_exit "stage --help" 0 $?
node "$STAGE" --out "$SB/out" >/dev/null 2>&1;              expect_exit "stage without input is usage error" 2 $?
node "$STAGE" --dir "$SB/src" --out "$SB/out" >/dev/null 2>&1; expect_exit "corrupt png is bad input" 3 $?
rm "$SB/src/broken.png"

# no names/arms -> staged, but exit 10 with flags
printf '%s\n' "$SB/src/shotcraft_example.com/macbook/abc123-example-macbook-sectn-02-hero--section.png" > "$SB/list.txt"
J="$(node "$STAGE" --list "$SB/list.txt" --dir "$SB/src" --out "$SB/out" --json 2>/dev/null)"; RC=$?
expect_exit "stage flags missing subject/arm with exit 10" 10 $RC
node -e '
const j=JSON.parse(require("fs").readFileSync(0,"utf8")); const by=Object.fromEntries(j.images.map(i=>[i.name,i]));
let f=0; const say=(o,m)=>{console.log(`  ${o?"PASS":"FAIL"}  [stage] ${m}`); if(!o)f++;};
say(j.images.length===3, "three images staged");
say(by["01-example-hero"] && by["01-example-hero"].w===3 && by["01-example-hero"].h===2, "shotcraft name -> 01-example-hero, PNG dims 3x2");
say(by["02-ref-needs-name"] && by["02-ref-needs-name"].w===40 && by["02-ref-needs-name"].h===30, "IMG_0001.JPG -> needs-name, JPEG dims 40x30");
say(by["03-ref-brand-sheet"] && by["03-ref-brand-sheet"].w===8 && by["03-ref-brand-sheet"].h===4, "brand-sheet.gif -> keeps subject, GIF dims 8x4");
say(by["02-ref-needs-name"].flags.includes("needs-subject"), "meaningless name is flagged needs-subject");
say(j.images.every(i=>i.flags.includes("needs-arm")), "every image flagged needs-arm without --arms");
say(require("fs").existsSync(by["01-example-hero"].file), "staged copy exists on disk");
process.exit(f?1:0)' <<<"$J" && ok "stage output shape" || no "stage output shape"
[[ -f "$SB/src/IMG_0001.JPG" ]] && ok "originals untouched" || no "originals untouched"

# names + arms supplied -> exit 0, planner accepts the output end to end
echo '{"IMG_0001.JPG":"Collected System"}' > "$SB/names.json"
echo '{"01-example-hero":"N","02-ref-collected-system":"E","03-ref-brand-sheet":"S"}' > "$SB/arms.json"
rm -rf "$SB/out"
node "$STAGE" --list "$SB/list.txt" --dir "$SB/src" --out "$SB/out" --names "$SB/names.json" --arms "$SB/arms.json" --json > "$SB/board.json" 2>/dev/null
expect_exit "stage with names+arms exits 0" 0 $?
grep -q '"name": "02-ref-collected-system"' "$SB/board.json" && ok "--names override becomes the slug" || no "--names override becomes the slug"
node "$PLAN" --input "$SB/board.json" --mode loose --json >/dev/null 2>&1; expect_exit "planner accepts stage output" 0 $?

echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
