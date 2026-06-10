# Argument Parsing — deep dive

Robust, agent-facing argument handling. The resource protocol requires `--help`
with EXAMPLES (exit 0 to stdout) and a hard USAGE error (exit 2) on unknown flags
or extra positionals. Two idioms cover everything: the **`case` loop** (preferred,
long-flag capable) and **`getopts`** (short-flags only, more compact).

## The `case` loop (preferred)

Handles long flags (`--json`), short flags, value-taking flags, `--flag=value`,
and the `--` end-of-options sentinel. This is what `preinstall-check.sh` uses.

```bash
usage() {
  cat <<'EOF'
Usage: tool [OPTIONS] <input>...
  --json            emit JSON to stdout
  --out FILE        write result to FILE (default: stdout)
  --retries N       retry N times (default: 3)
  -q, --quiet       suppress progress on stderr
  -h, --help        show this help

EXAMPLES:
  tool input.txt
  tool --json --out result.json a.txt b.txt
  tool --retries 5 -q input.txt
EOF
}

JSON=0; QUIET=0; OUT=""; RETRIES=3; ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)        JSON=1 ;;
    -q|--quiet)    QUIET=1 ;;
    --out)         OUT="${2:?--out needs a value}"; shift ;;
    --out=*)       OUT="${1#*=}" ;;
    --retries)     RETRIES="${2:?--retries needs a value}"; shift ;;
    --retries=*)   RETRIES="${1#*=}" ;;
    -h|--help)     usage; exit 0 ;;
    --)            shift; ARGS+=("$@"); break ;;
    -*)            printf 'ERROR: unknown flag: %s (try --help)\n' "$1" >&2; exit 2 ;;
    *)             ARGS+=("$1") ;;
  esac
  shift
done

# validation
[[ ${#ARGS[@]} -ge 1 ]] || { printf 'ERROR: need at least one input (try --help)\n' >&2; exit 2; }
[[ "$RETRIES" =~ ^[0-9]+$ ]] || { printf 'ERROR: --retries must be an integer\n' >&2; exit 2; }
```

Key points:

- **Value-taking flags** consume `$2` then `shift` an extra time. `${2:?msg}` aborts
  with `msg` if the value is missing — clean for `set -u` scripts.
- **`--flag=value` form** handled by a parallel `--flag=*` arm using `${1#*=}`
  (strip up to the first `=`).
- **`--` sentinel** stops option parsing: everything after is positional, even if it
  starts with `-`. Essential when an input filename might be `-weird`.
- **Unknown flag** (`-*`) is a hard exit 2 — never silently ignore (protocol §6).
- **Positionals** accumulate into an array so spaces survive; consume them with
  `"${ARGS[@]}"`.
- Validate *after* parsing: required count, integer ranges, file existence (exit 3
  for a missing input file per §5).

## `getopts` (short flags only)

POSIX-portable, compact, but **no long-flag support** and no `--flag=value`. Good
for a small script with only single-letter options.

```bash
JSON=0; OUT=""; verbose=0
while getopts ':jo:vh' opt; do
  case "$opt" in
    j) JSON=1 ;;
    o) OUT="$OPTARG" ;;          # ':' after o means it takes a value
    v) verbose=1 ;;
    h) usage; exit 0 ;;
    :) printf 'ERROR: -%s needs a value\n' "$OPTARG" >&2; exit 2 ;;
    \?) printf 'ERROR: unknown flag: -%s\n' "$OPTARG" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))            # drop parsed options; "$@" is now positionals
```

- The **leading `:`** in `':jo:vh'` enables *silent* error mode, letting you handle
  `:` (missing value) and `\?` (unknown) yourself with proper exit-2 messages.
- A letter followed by `:` (here `o:`) takes a value in `$OPTARG`.
- `shift $((OPTIND - 1))` discards the consumed options so `"$@"` holds positionals.
- Limitations that push you to the `case` loop: `getopts` cannot do `--json`,
  cannot do `--out=x`, and clustering long flags is impossible. For anything an
  agent invokes by long name, use the `case` loop.

## Choosing between them

| Need | Use |
|---|---|
| Any long flag (`--json`, `--dry-run`) | `case` loop |
| `--flag=value` form | `case` loop |
| Agent-facing skill script | `case` loop (matches the exemplar) |
| Tiny script, only `-x -y -z` short flags, max portability | `getopts` |

## The `--help` contract (both styles)

- Writes to **stdout** and exits **0** (it is requested output, not an error).
- Includes a usage line, every option, and an **EXAMPLES** block — the protocol
  makes EXAMPLES mandatory because it is what makes the tool discoverable when the
  agent runs `--help`.
- A common compact trick (used by `preinstall-check.sh`) is to render help from the
  first-comment-block itself: `sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'` — single
  source of truth for the contract and the help text.
