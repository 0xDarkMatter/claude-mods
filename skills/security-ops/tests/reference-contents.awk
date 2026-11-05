# reference-contents.awk - does each reference open with a current `## Contents` list?
#
# For every input file longer than `min_lines` (default 0 = check all), prints one
# TAB-separated line per problem, prefixed by the file name:
#   <file>	no ## Contents in first 15 lines
#   <file>	missing: <heading text>       (a `## ` heading the list does not name;
#                                          matched as a substring of the list text)
# A file with a current list prints nothing, unless `-v emit_checked=1`, which adds a
# `<file>	checked` line for every file over the threshold (so a caller can count them).
# Headings inside ``` / ~~~ fences are ignored, and CRLF input is read as LF.
#
# Shared on purpose, so there is one parser and the two checks cannot disagree:
#   - this skill's own suite (tests/run.sh) fails on any problem in its references
#   - the repo-wide warn-only gate (tests/reference-contents.sh) runs it over every skill
# It lives inside security-ops, not in tests/ or skills/_lib, because security-ops is
# copied standalone into other plugins and its suite must run without this repo.
# Moving it breaks the repo gate loudly (exit 2), never silently.
#
# Multi-file without gawk's ENDFILE: a file's verdict is flushed when the next file
# starts (FNR == 1) and at END. An empty file yields no records and is skipped.
#
# Usage: awk [-v min_lines=N] [-v emit_checked=1] -f reference-contents.awk FILE...

function flush(    i) {
    if (file == "" || lines <= min_lines) return
    if (emit_checked) print file "\tchecked"
    if (!seen || seen > 15) { print file "\tno ## Contents in first 15 lines"; return }
    for (i = 1; i <= n; i++) if (index(toc, heads[i]) == 0) print file "\tmissing: " heads[i]
}
FNR == 1 { flush(); file = FILENAME; fence = 0; in_toc = 0; seen = 0; n = 0; toc = ""; split("", heads) }
{ sub(/\r$/, ""); lines = FNR }
/^[[:space:]]*(```|~~~)/ { fence = !fence; next }
fence { next }
/^## / {
    h = substr($0, 4)
    if (h == "Contents") { in_toc = 1; seen = FNR; next }
    in_toc = 0; heads[++n] = h; next
}
# Link markup is dropped so `1. [Alpha](#1-alpha)` names the heading `## 1. Alpha`
in_toc { line = $0; gsub(/\]\([^)]*\)/, "", line); gsub(/\[/, "", line); toc = toc "\n" line }
END { flush() }
