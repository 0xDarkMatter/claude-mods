# Codepoint Bands and the Severity Model

Every band the scanner names, with range and severity, and the policy the two
scripts apply to them: which severities fail a scan, which strip level removes
what, and when a band is replaced by a space instead of deleted. Techniques behind
each band: [threat-techniques.md](threat-techniques.md) and
[line-breaks-and-controls.md](line-breaks-and-controls.md).

## Contents

1. [Band table](#band-table)
2. [The severity model](#the-severity-model)

## Band table

The full, authoritative catalog is `assets/dangerous-codepoints.json`; this is
its human-readable map.

| Band | Range | Severity | Note |
|---|---|---|---|
| Tag-block (ASCII smuggling) | `U+E0000`-`U+E007F` | critical | Invisible; encodes full hidden instructions |
| Bidi overrides | `U+202A`-`U+202E` | critical | Trojan Source reordering |
| Bidi isolates | `U+2066`-`U+2069` | high | Subtler reordering; legit in mixed-direction text |
| Zero-width space / word-joiner | `U+200B`, `U+2060`-`U+2064` | high | Invisible separators / filter evasion |
| Line / paragraph separators, NEL, FS-US | `U+2028`-`U+2029`, `U+0085`, `U+001C`-`U+001F` | high | Forge a line break; flattened to a space |
| ESC (ANSI escape sequences) | `U+001B` | high | Conceals / erases text in a terminal review |
| C0 controls, DEL, C1 controls | `U+0000`-`U+0008`, `U+000E`-`U+001A`, `U+007F`, `U+0080`-`U+009F` (not NEL) | high | BS overprints; NUL makes `git diff` show "binary"; `U+009B` is 8-bit CSI. TAB/LF/CR unbanded |
| Soft hyphen, CGJ, Khmer inherent vowels, Hangul fillers | `U+00AD`, `U+034F`, `U+17B4`-`U+17B5`, `U+115F`-`U+1160`, `U+3164`, `U+FFA0` | high | Default-ignorable; keyword splitting |
| Deprecated + musical format characters | `U+206A`-`U+206F`, `U+1D173`-`U+1D17A` | high | Default-ignorable; no living use |
| Reserved default-ignorables | `U+2065`, `U+FFF0`-`U+FFF8`, `U+E0080`-`U+E00FF`, `U+E01F0`-`U+E0FFF` | high | Unassigned, yet already invisible by property |
| VT / FF | `U+000B`-`U+000C` | medium | Line breaks, but visible in a raw-byte review |
| Mongolian vowel separator + free variation selectors | `U+180B`-`U+180F` | medium | Invisible; required in Mongolian (like ZWNJ) |
| Shorthand format controls | `U+1BCA0`-`U+1BCA3` | medium | Invisible; required in Duployan shorthand |
| BOM mid-file | `U+FEFF` | medium | Legit only at byte 0 |
| Variation selectors | `U+FE00`-`U+FE0F` | low | `U+FE0F` whitelisted (emoji) |
| Private use areas | `U+E000`-`U+F8FF`, supp. | low | Icon fonts; suspicious in prose |
| ZWJ | `U+200D` | benign | Whitelisted - emoji/Indic |

**Exit codes (both scripts):** `0` ok · `2` usage · `3` not-found · `4` validation ·
`5` missing catalog · `10` indicator found (scan only).

## The severity model

The catalog (`assets/dangerous-codepoints.json`) assigns each band a `severity` and
a `strip_level`. The two scripts apply them as policy:

| Severity | Scanner default | Scanner `--strict` | Legitimate use? |
|---|---|---|---|
| critical | fail (exit 10) | fail | none — always hostile |
| high | fail | fail | rare / multilingual-only |
| medium | pass | fail | script-specific |
| low | pass | fail | icon fonts, emoji selectors |
| benign | pass | pass | emoji, Indic — never flagged |

| `strip_level` | `minimal` | `standard` (default) | `aggressive` |
|---|---|---|---|
| Removes | critical only | + high + medium | + low |
| Emoji-safe? | yes | yes | **no** (strips VS16) |
| Multilingual-safe? | yes | yes (keeps ZWNJ/ZWJ) | no (strips ZWNJ) |

Bands with a `replace_with` code point in the catalog are *replaced*, not deleted, at
their strip level: the line-break class and the blank-rendering Hangul fillers become
`U+0020` (see [Line breaks that forge structure](line-breaks-and-controls.md#line-breaks-that-forge-structure)).
The rule for choosing: delete what renders as nothing, replace what a reader sees as
a gap or a break. A band whose code points the chart splits uses a `ranges` list of
spans instead of one `start`/`end`; bands never overlap.

Severity for the line-break, control and invisible-filler bands, against the table
above:

| Band | Code points | Severity | Why |
|---|---|---|---|
| `line-paragraph-separators` | `U+2028`-`U+2029` | high | Mandatory breaks (UAX #14 BK) that LF-terminated text never needs; many viewers draw nothing or stay inline |
| `next-line` | `U+0085` | high | UAX #14 NL; EBCDIC-only; a C1 control most viewers draw as nothing |
| `information-separators` | `U+001C`-`U+001F` | high | FS-RS are `str.splitlines()` boundaries, US a segment separator; no use in text; invisible in terminals |
| `vertical-tab-form-feed` | `U+000B`-`U+000C` | medium | Line breaks too, but a raw-byte review shows them and FF is a legitimate page break |
| `c0-controls`, `ascii-delete`, `c1-controls` | `U+0000`-`U+0008`, `U+000E`-`U+001A`, `U+007F`, `U+0080`-`U+009F` but NEL | high | Terminal commands or nothing at all; NUL hides a `git diff`; no use in text |
| `escape` | `U+001B` | high | Conceals or erases text in a terminal review; not critical because captured coloured output is legitimate |
| `soft-hyphen`, `combining-grapheme-joiner`, `khmer-inherent-vowels`, `hangul-jamo-fillers`, `hangul-filler`, `hangul-halfwidth-filler` | see above | high | Invisible, and no living orthography requires them |
| `deprecated-format-characters`, `musical-format-characters` | `U+206A`-`U+206F`, `U+1D173`-`U+1D17A` | high | Invisible; deprecated, or markup nothing implements |
| `reserved-default-ignorable` | `U+2065`, `U+FFF0`-`U+FFF8`, `U+E0080`-`U+E00FF`, `U+E01F0`-`U+E0FFF` | high | Unassigned, so no legitimate text; already invisible by property |
| `mongolian-vowel-separator`, `mongolian-free-variation-selectors` | `U+180B`-`U+180F` | medium | Invisible, but required in Mongolian - script-specific, like ZWNJ |
| `shorthand-format-controls` | `U+1BCA0`-`U+1BCA3` | medium | Invisible, but required in Duployan shorthand - script-specific |

Rule of thumb: **scan with defaults** (catches the unambiguous attacks without noise),
escalate to `--strict` when impersonation or steganography is plausible. **Sanitize
at `standard`** for untrusted content you still want readable; reserve `aggressive`
for plain prose where you don't mind losing emoji/icon glyphs.
