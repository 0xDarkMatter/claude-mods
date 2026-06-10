# Strict Mode and Traps — deep dive

The error-handling backbone of a defensive Bash script. The SKILL.md body covers
the three-line preamble; this file covers the edge cases that bite in production.

## The four flags, precisely

### `set -e` (errexit) — and where it silently does nothing

`set -e` aborts the script when a command returns non-zero. It is the most useful
and the most misunderstood flag because of where it **does not** fire:

1. **Conditions.** A command in an `if`, `while`, `until`, `&&`, `||`, or negated
   with `!` is a *tested* command — its failure is expected, so `-e` ignores it.
   ```bash
   if ! grep -q foo file; then …    # grep failing here does NOT abort
   ```
2. **Inside functions called in a condition.** If `f` is invoked as `if f; then`,
   `-e` is disabled *for the entire body of `f`* (POSIX behaviour). A failing
   command deep inside `f` won't abort. This surprises everyone once.
3. **Non-final pipe stages.** Without `pipefail`, only the last command's status
   counts: `false | true` succeeds. Add `set -o pipefail`.
4. **`local`/`declare` masking.** `local x=$(cmd)` — the *assignment builtin*
   returns 0 even if `cmd` failed. Split the declaration from the assignment:
   ```bash
   local x; x=$(cmd)    # now $? reflects cmd, and -e can fire
   ```
5. **Command substitution in an unchecked statement.** `echo "$(false)"` does not
   abort under older Bash because the outer `echo` succeeds. Assign first if the
   substitution's success matters.

**When to drop `-e`.** Scripts that *inspect* exit codes themselves (a checker that
branches on whether `curl` got a 404 vs a network error) must NOT let `-e` kill the
run on the first non-zero. Those use `set -uo pipefail` and check `$?` explicitly —
this is exactly what `preinstall-check.sh` does, and why the resource protocol §2
says "use `-e` only when every failure is fatal."

### `set -u` (nounset)

Expanding an unset variable becomes a fatal error instead of an empty string —
catches typos (`$fil` vs `$file`) and missing arguments.

- `"$1"` when no `$1` was passed → aborts. Guard: `"${1:-default}"` or
  `[[ $# -ge 1 ]] || { usage; exit 2; }`.
- **Empty-array gotcha:** in Bash before 4.4, `"${arr[@]}"` on an empty array trips
  `-u`. Use `"${arr[@]:-}"` or test `[[ ${#arr[@]} -gt 0 ]]` first. (Bash 4.4+ fixed
  this for `@`/`*`.)

### `set -o pipefail`

A pipeline's exit status becomes the rightmost **non-zero** status (or 0 if all
succeed). Without it, a failing producer is invisible:

```bash
set -o pipefail
data="$(curl -fsS "$url" | jq '.x')"   # now a curl failure fails the assignment
```

**SIGPIPE / 141 caveat:** when a consumer closes the pipe early (`producer | head -1`),
the producer is killed by SIGPIPE and reports `141`. With `pipefail` this surfaces as
a pipeline failure even though nothing is wrong. Tolerate it for truncating
consumers: `{ big_producer || [[ $? -eq 141 ]]; } | head`.

### `set -E` (errtrace)

Makes an `ERR` trap inherit into shell functions, command substitutions, and
subshells. Without `-E`, your nice line-number-reporting `ERR` trap silently fails
to fire inside functions. Always pair `-E` with an `ERR` trap.

## ERR trap with context

```bash
set -Eeuo pipefail

err() {
  local rc=$?
  printf 'ERROR: rc=%d at %s:%d in %s()\n' \
    "$rc" "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" "${FUNCNAME[1]:-main}" >&2
  exit "$rc"
}
trap err ERR
```

`BASH_LINENO`/`BASH_SOURCE`/`FUNCNAME` are parallel stack arrays — index `[0]`/`[1]`
walk up the call stack. This turns "it failed somewhere" into "it failed at
deploy.sh:42 in push_image()".

## EXIT trap — cleanup that always runs

```bash
tmpdir="$(mktemp -d)"
cleanup() {
  local rc=$?            # capture BEFORE any command in cleanup changes $?
  rm -rf -- "$tmpdir"
  exit "$rc"            # preserve the original exit code
}
trap cleanup EXIT
```

- `EXIT` fires on normal exit, `set -e` abort, `exit N`, and — if not separately
  trapped — after the default signal handlers. It is the single most reliable place
  to release resources.
- **Capture `$?` as the first line** of the handler. Any command inside `cleanup`
  overwrites `$?`, so grab it before `rm` et al.
- A `trap … EXIT` set in a subshell only covers that subshell.

## Signal handling

```bash
interrupted=0
on_int() { interrupted=1; printf '\ninterrupted, cleaning up…\n' >&2; }
trap on_int INT TERM
```

- `INT` (Ctrl-C), `TERM` (`kill`), `HUP` (terminal closed) are the common ones.
- After handling a signal, `EXIT` still runs — so put resource release in the EXIT
  handler and use signal handlers only for *additional* behaviour (a message, a
  flag).
- To re-raise a signal with the correct exit code (`128 + signum`), reset and
  resend: `trap - INT; kill -INT $$`.
- `trap '' INT` ignores a signal; `trap - INT` restores the default.

## Idempotency and atomic writes

The resource protocol §6 requires re-running with the same inputs to be safe.

- Never write the destination directly. Write `"$dst.tmp"` (or a `mktemp` file on
  the same filesystem) and `mv -- "$tmp" "$dst"`. `mv` within one filesystem is
  atomic — a concurrent reader sees old-or-new, never a partial file. (`mv` across
  filesystems falls back to copy+unlink and is *not* atomic — keep the temp beside
  the destination.)
- Guard creation with `mkdir -p` (idempotent) rather than `mkdir` (fails if exists).
- For "create only if absent" use `set -C` (noclobber) + `>` or `mkdir` as a lock.
