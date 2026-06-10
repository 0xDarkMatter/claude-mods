# Bash Footguns — reproducers and mechanisms

Each entry: what breaks, *why* at the shell-mechanics level, and the fix. These are
the bugs `shellcheck` and `set -Eeuo pipefail` exist to catch.

## 1. Unquoted expansion → word splitting + globbing

```bash
file="my report.txt"
rm $file            # runs: rm my report.txt   → tries to remove TWO files
rm "$file"          # correct
```

**Mechanism.** After parameter expansion, an *unquoted* result undergoes (a) word
splitting on `IFS` (default: space/tab/newline) then (b) pathname expansion
(globbing). `*.bak` in a variable expands to matching files; `a b` splits to two
args. Quoting suppresses both. This is the single most common shell bug.

Fix: quote everything — `"$file"`, `"${arr[@]}"`. Set `IFS=$'\n\t'` to drop space
from the split set as defence-in-depth.

## 2. `[ ]` vs `[[ ]]`

```bash
[ -n $x ]                  # if $x is empty/unset → [ -n ] → true (wrong!)
[ "$a" == "$b" ]           # == is non-POSIX in [; && doesn't work; word-splits
[[ -n $x ]]                # safe: [[ ]] does not word-split its operands
[[ "$a" == "$b" && -f c ]] # &&, ==, < all work inside [[ ]]
```

**Mechanism.** `[` is the external/builtin `test` command — its operands are
subject to normal word splitting, so an unquoted empty variable vanishes and
changes the expression's arity. `[[ ]]` is a Bash *keyword*: it parses operands
without word splitting or globbing, supports `&&`/`||`/`<`/`==` with pattern
matching and `=~` for regex. Use `[[ ]]` in Bash always; reserve `[ ]` for strict
POSIX `sh` scripts.

## 3. `$?` after assignment is always 0

```bash
output=$(might_fail)
echo $?              # prints 0 — the ASSIGNMENT succeeded, not might_fail
```

**Mechanism.** A simple assignment's exit status is that of the *last command
substitution*, but a plain `var=$(cmd)` reports the assignment builtin's status,
which is 0 unless the substitution itself errors fatally. Capture inline:

```bash
if ! output=$(might_fail); then echo "failed" >&2; fi
# or
output=$(might_fail); rc=$?       # rc only reliable when not 'local'/'declare'
```

## 4. Pipe into `while read` loses variables (subshell)

```bash
count=0
printf 'a\nb\nc\n' | while read -r line; do count=$((count+1)); done
echo "$count"        # prints 0 — the while ran in a subshell
```

**Mechanism.** Each stage of a pipeline runs in its **own subshell**. The `while`'s
variable mutations happen in a child process and evaporate when it exits. Fixes:

```bash
# process substitution — while runs in the current shell
count=0
while read -r line; do count=$((count+1)); done < <(printf 'a\nb\nc\n')
echo "$count"        # 3

# or a here-string / file redirect
while read -r line; do …; done <<< "$data"
```

(Bash's `shopt -s lastpipe` runs the last pipe stage in the current shell, but only
non-interactively and with job control off — process substitution is more portable.)

## 5. `local x=$(cmd)` masks failure under `set -e`

```bash
set -e
get() { local v=$(false); echo "reached"; }   # 'reached' prints — failure hidden
get() { local v; v=$(false); echo "nope"; }    # aborts at v=$(false)
```

**Mechanism.** `local`/`declare`/`export` are commands; their exit status is the
builtin's (0 on a valid declaration), which overrides the substitution's failing
status. `set -e` sees 0 and continues. Always split declaration and assignment when
the command's success matters.

## 6. `echo` is not portable for data

```bash
echo "-n"            # may print nothing (treated as a flag) or "-n"
echo "a\tb"          # prints literal \t or a tab depending on shell/xpg_echo
printf '%s\n' "$x"   # correct, deterministic
```

**Mechanism.** `echo`'s handling of `-n`, `-e`, and backslash escapes is
unspecified across shells and `shopt xpg_echo`. For any variable data, use
`printf '%s\n'`. Reserve `echo` for fixed, escape-free literals.

## 7. `for f in $(ls)` / parsing `ls`

```bash
for f in $(ls *.txt); do …   # breaks on spaces, newlines, globs in names
for f in *.txt; do            # correct: glob directly, no ls
  [[ -e "$f" ]] || continue   # handle "no matches" (glob stays literal)
  …
done
```

**Mechanism.** `$(ls)` produces a single string that word-splits on whitespace — a
filename with a space becomes two loop iterations. Globbing (`*.txt`) yields each
match as one word safely. Guard the no-match case (a non-matching glob expands to
itself unless `shopt -s nullglob`).

## 8. Reading a file line-by-line

```bash
while IFS= read -r line; do
  printf 'got: %s\n' "$line"
done < "$file"
# trailing line with no newline:
while IFS= read -r line || [[ -n "$line" ]]; do …; done < "$file"
```

**Mechanism.** `IFS=` (empty) stops leading/trailing whitespace trimming; `-r`
stops backslash interpretation. Without both, indentation and backslashes are
mangled. The `|| [[ -n "$line" ]]` clause catches a final line lacking a newline
(`read` returns non-zero but still sets `line`).

## 9. `pipefail` + early-closing consumer = exit 141

```bash
set -o pipefail
generate_huge_stream | head -5    # head exits after 5 lines → SIGPIPE to generator
echo $?                            # 141 (128 + 13) even though nothing is wrong
```

**Mechanism.** When `head` closes the read end, the producer gets SIGPIPE (signal
13) and dies with `128+13=141`; `pipefail` propagates that as the pipeline status.
Tolerate it: `{ generate_huge_stream || [[ $? -eq 141 ]]; } | head -5`.

## 10. Empty array under `set -u` (older Bash)

```bash
set -u
arr=()
printf '%s\n' "${arr[@]}"     # Bash <4.4: "unbound variable" error
printf '%s\n' "${arr[@]:-}"   # safe everywhere
```

**Mechanism.** Pre-4.4 Bash treated `"${arr[@]}"` of an empty array as referencing
an unset variable under `-u`. Use `"${arr[@]:-}"`, or test `((${#arr[@]}))` first.
Fixed in Bash 4.4 for `@`/`*`, but the guard keeps scripts portable to macOS 3.2
and old CI images.

## 11. `cd` without checking, then destructive op

```bash
cd "$dir" && rm -rf -- ./*     # if cd fails, rm never runs (good)
cd "$dir"; rm -rf -- ./*       # if cd fails (under no -e), rm runs in WRONG dir
```

**Mechanism.** A failed `cd` (typo, missing dir) leaves you in the *current*
directory. A following unconditional `rm -rf ./*` then wipes the wrong tree. Always
`cd … || exit 1`, or chain with `&&`, or run under `set -e`. Add `--` and `./`
prefixes so a path beginning with `-` is data, not flags.
