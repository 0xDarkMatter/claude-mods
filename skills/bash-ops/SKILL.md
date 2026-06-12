---
name: bash-ops
description: "Defensive Bash scripting for production automation, CI scripts, and agent-facing tools. Triggers on: bash, shell script, defensive bash, bash strict mode, set -euo pipefail, set -Eeuo pipefail, shellcheck, trap, IFS, cleanup trap, mktemp, getopts, argument parsing, exit codes, stream separation, stdout stderr, quoting, word splitting, pipefail, subshell, CI script, shell footgun, bats, shfmt, POSIX, portable shell."
license: MIT
allowed-tools: "Read Write Edit Bash"
metadata:
  when_to_use: "Use when writing or reviewing any Bash/shell script — especially skill scripts, CI steps, and automation that must fail safely. Covers strict mode, quoting, argument parsing, traps/cleanup, safe tempfiles, the stream-separation + exit-code contract, and shellcheck."
  author: claude-mods
  related-skills: cli-ops, ci-cd-ops
---

# Bash Operations

Defensive Bash for scripts that run unattended — CI steps, automation, and the
`scripts/` a skill ships. The goal: a script that **fails loudly on the first
problem, never corrupts state, and emits parseable output**.

This is the house standard for any shell script in this repo. The script contract
below is the same one enforced by
[`docs/SKILL-RESOURCE-PROTOCOL.md`](../../docs/SKILL-RESOURCE-PROTOCOL.md) §2–§7 —
that protocol governs every skill resource, and its rules *are* bash rules. Treat
the two as one standard: the resource protocol decides **what** a skill script must
guarantee (streams, exit codes, help block); this skill teaches **how** to write
the Bash that delivers it. The canonical reference implementation is
[`skills/supply-chain-defense/scripts/preinstall-check.sh`](../supply-chain-defense/scripts/preinstall-check.sh) —
read it whenever you need a worked example of every rule here applied at once.

## Bash vs Python — choose before you write

Reach for Python (and the `python-cli-ops` skill) when a script grows past
**~100 lines**, needs **data structures** (nested maps, JSON manipulation beyond a
`jq` filter), arithmetic beyond integers, or string processing with real parsing.
Bash excels at **gluing processes together**: launching tools, moving files,
checking conditions, wiring pipelines. The moment you find yourself simulating a
hash-of-hashes or doing float math, stop — that's Python's job. This mirrors
SKILL-RESOURCE-PROTOCOL §3, which expects `.sh` for shell glue and `.py` for logic.

## Strict mode — the first three lines

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
```

Each flag earns its place — and each has a sharp edge:

| Flag | Buys you | The edge to know |
|---|---|---|
| `set -e` | Abort on any unchecked non-zero command | Does **not** fire inside `if`/`&&`/`||` conditions, in a function called in such a context, or for the *non-last* command of a pipe. `local x=$(cmd)` masks `cmd`'s failure — `local` returns 0. Split: `local x; x=$(cmd)`. |
| `set -u` | Error on unset variable expansion | `"$@"` and `"${arr[@]}"` on an empty array trip `-u` in old Bash; use `"${arr[@]:-}"` or guard with Bash 4.4+. |
| `set -o pipefail` | A pipe fails if **any** stage fails, not just the last | Without it, `grep x file | head` hides a `grep` error. With it, a `head` that closes the pipe early can surface `141` (SIGPIPE) — expected, not a bug. |
| `set -E` | `ERR` trap inherits into functions/subshells/command-subs | Pair with a `trap … ERR` that reports `$LINENO`. |
| `IFS=$'\n\t'` | Word-splitting only on newline/tab, never spaces | Filenames with spaces stop splitting into pieces. Unset/space-IFS is the #1 cause of "it worked until a path had a space". |

`set -e` is the contested one. Use the full `set -Eeuo pipefail` when **every**
unchecked failure should abort (most scripts). Drop to `set -uo pipefail` when the
script deliberately inspects exit codes itself (the resource-protocol exemplars do
this — they branch on registry exit codes, so a non-zero `curl` must not kill the
run). Decide consciously; don't cargo-cult either way.

→ Full treatment, ERR-trap recipes, and the `set -e` exemption rules:
[`references/strict-mode-and-traps.md`](references/strict-mode-and-traps.md).

## Quoting discipline

**Quote every expansion** unless you have a specific, commented reason not to.

```bash
cp "$src" "$dst"                 # not cp $src $dst  — breaks on spaces/globs
for f in "${files[@]}"; do …     # not ${files[@]}   — array stays element-safe
rm -- "$path"                    # -- ends options; $path starting with - is data
[[ -n "$x" ]]                    # [[ ]] doesn't word-split, but quote for habit
grep -- "$pattern" "$file"
```

- Unquoted `$var` undergoes **word splitting** (on `IFS`) then **glob expansion**.
  A variable holding `*.txt` or `a b` becomes multiple args. This is the canonical
  footgun.
- `"$@"` (quoted) preserves arguments exactly; `$@` and `$*` mangle them. Always
  `"$@"` to forward args.
- Use `--` before user/agent-supplied operands so a value like `-rf` is treated as
  data, not flags.

## Argument parsing — case-based long flags

The resource protocol mandates `--help` with an EXAMPLES section and rejects
unknown flags with a USAGE error (exit 2). Use a `while`/`case` loop — it handles
GNU-style long flags (`--json`, `--dry-run`), which `getopts` cannot:

```bash
JSON=0; DRY_RUN=0; ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)      JSON=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; ARGS+=("$@"); break ;;   # everything after -- is positional
    -*)          printf 'ERROR: unknown flag: %s (try --help)\n' "$1" >&2; exit 2 ;;
    *)           ARGS+=("$1") ;;
  esac
  shift
done
```

`getopts` is fine for **short flags only** (`-v -o file`) and is more compact there,
but it has no long-flag support and clusters awkwardly. Prefer the `case` loop for
anything agent-facing — it matches `preinstall-check.sh` exactly.

→ Both styles in full, value-taking flags, `--flag=value`, and validation:
[`references/argument-parsing.md`](references/argument-parsing.md).

## Traps, cleanup, and safe tempfiles

Never leave a tempfile or half-written output behind. Create temp paths with
`mktemp`, register a cleanup `trap` **immediately after**, and write atomically.

```bash
tmp="$(mktemp)" || exit 1
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT          # fires on normal exit, error, and signals via EXIT

build_output >"$tmp"       # write to temp
mv -- "$tmp" "$dst"        # atomic rename — reader never sees a partial file
trap - EXIT; rm -f "$tmp"  # (optional) disarm after successful move
```

- `trap cleanup EXIT` is the workhorse — `EXIT` fires for normal exit, `set -e`
  abort, and (in practice) `INT`/`TERM` if you let them propagate. Add explicit
  `trap cleanup INT TERM` if you do signal handling yourself.
- `mktemp -d` for a temp **directory**; clean it with `rm -rf -- "$tmpdir"`.
- **Atomic write = `tmp` + `mv`** (same filesystem). A reader sees either the old
  file or the complete new one, never a truncated mid-write — exactly the
  idempotency the resource protocol §6 requires.

→ Signal handling, ERR-trap with line numbers, nested traps:
[`references/strict-mode-and-traps.md`](references/strict-mode-and-traps.md).

## The stream-separation + exit-code contract

This is the load-bearing rule for any agent-facing script, lifted directly from
SKILL-RESOURCE-PROTOCOL §4–§5. Claude parses stdout; pollution breaks `| jq`.

- **stdout = the data product only.** JSON under `--json`, else plain/TSV.
- **stderr = everything else.** Headers, progress, warnings, errors, prompts.
- **Semantic exit codes**, not just 0/1:

| Code | Meaning |
|---|---|
| `0` | success |
| `2` | usage (bad/missing args, unknown flag) |
| `3` | not found (input absent) |
| `4` | validation (input present but malformed) |
| `5` | precondition (missing dependency, wrong cwd) |
| `7` | unavailable (external resource down — *advisory*, not a real failure) |
| `10`+ | domain signal — a non-error "finding" the caller branches on |

Code `10` is the workhorse for verifiers/scanners: "ran fine, found something."
Reserve `7` so a network blip never looks like a content failure. Print human
framing to stderr, the record to stdout:

```bash
printf '%s\t%s\n' "$name" "$status"          # data → stdout
printf '  [ok] %s checked\n' "$name" >&2      # framing → stderr
```

→ The shipped [`assets/script-template.sh`](assets/script-template.sh) bakes this
contract in — copy it as the starting point for any new skill script.

## ShellCheck — non-negotiable

Run [`shellcheck`](https://www.shellcheck.net/) on every script; it catches the
quoting/word-splitting/`set -e` bugs above mechanically.

```bash
shellcheck script.sh                  # lint
shellcheck -x script.sh               # follow sourced files
shfmt -i 2 -ci -w script.sh           # format (2-space indent, indent switch-cases)
```

- Fix warnings; don't blanket-suppress. When a suppression is genuinely correct,
  scope it to one line with a reason: `# shellcheck disable=SC2086 # word split intended`.
- CI gate: `shellcheck **/*.sh` should pass clean before merge.
- `bash -n script.sh` is a free syntax-only check (no execution) — run it in tests.

## Common footguns (quick table)

| Footgun | Why it bites | Fix |
|---|---|---|
| Unquoted `$var` | Word-split + glob expansion | `"$var"` always |
| `[ "$a" == "$b" ]` | `[` is POSIX `test`; `==` non-portable, no `&&` grouping | `[[ "$a" == "$b" ]]` in Bash |
| `var=$(cmd) ; echo $?` | `$?` is the assignment's status (always 0), not `cmd`'s | `cmd; rc=$?` or check inline |
| `cmd | while read x; do total=$x; done` | `while` runs in a **subshell**; `$total` is lost after the pipe | `while …; do … done < <(cmd)` (process substitution) |
| `local x=$(cmd)` under `set -e` | `local` returns 0, masking `cmd` failure | `local x; x=$(cmd)` on two lines |
| `echo "$x"` for arbitrary data | `echo` mangles `-n`, `-e`, backslashes | `printf '%s\n' "$x"` |
| `for f in $(ls)` | Splits on whitespace, breaks on spaces/newlines | `for f in *` or `while IFS= read -r f` |
| `pipefail` + `head` shows `141` | Downstream closes pipe early (SIGPIPE) | Expected; tolerate `141` from truncating consumers |

→ Each footgun with a reproducer and the underlying mechanism:
[`references/footguns.md`](references/footguns.md).

## Bash version notes (attribute features correctly)

Bash is stable, but several common idioms are **version-gated**. macOS still ships
Bash **3.2** (2007, GPLv2); Linux/CI is usually Bash 5.x. If a script must run on
stock macOS, avoid the 4.x+ features below or guard with `((BASH_VERSINFO[0]>=4))`.

| Feature | Introduced | Notes |
|---|---|---|
| `mapfile` / `readarray` | Bash **4.0** | Read lines into an array. `mapfile -t arr < file`. `-d ''` (null-delimited) needs **4.4**. |
| Associative arrays (`declare -A`) | Bash **4.0** | Hash maps. Unavailable on macOS stock 3.2. |
| `${var,,}` / `${var^^}` (case conversion) | Bash **4.0** | Lowercase/uppercase expansion. |
| `&>>` append-both-streams, `|&` | Bash **4.0** | `cmd |& filter` = `cmd 2>&1 | filter`. |
| `${var@Q}` (quote operator) | Bash **4.4** | Produces a re-input-safe quoted form. Also `@U @L @E`. |
| `wait -n` (any child) | Bash **4.3** | Useful for bounded parallelism. |
| `local -n` (nameref) | Bash **4.3** | Pass array/var by reference into a function. |

When in doubt, state the requirement in the first-comment-block (`# Requires: bash 4+`)
and check at startup: `((BASH_VERSINFO[0] >= 4)) || { echo "needs bash 4+" >&2; exit 5; }`.

## Checklist before shipping a skill script

- [ ] `#!/usr/bin/env bash` + first-comment-block contract (desc, Usage, Exit, Examples)
- [ ] `set -Eeuo pipefail` (or a *deliberate* `set -uo pipefail`) + `IFS=$'\n\t'`
- [ ] All expansions quoted; `"$@"` to forward args; `--` before operands
- [ ] `case` arg loop; `--help` exits 0 with EXAMPLES; unknown flag → exit 2
- [ ] `trap cleanup EXIT` + `mktemp`; atomic `tmp`+`mv` writes
- [ ] stdout data-only, stderr for framing; semantic exit codes (§5)
- [ ] `shellcheck` clean; `bash -n` passes; `chmod +x`
- [ ] Version-gated features guarded or documented
