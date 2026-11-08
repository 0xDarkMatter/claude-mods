# Incident packs: format and how to add one

An incident pack is everything that is specific to one CA distrust event: the keys, the
test hosts, the first fixed releases. The checkers are generic and read one pack per run
(`--incident NAME`). This file is the format and the procedure; read it before adding or
changing a pack.

## Contents

- When an incident gets a pack
- The format
- Field rules
- Adding a pack, step by step
- Retiring a pack

## When an incident gets a pack

A pack is worth adding when command-line tools or language runtimes will keep trusting
something browsers have stopped trusting: a CA compromise, a distrust by root programs, a
root removal with a deadline. It needs public test hosts that serve a chain on the
distrusted keys (one host per trust path) plus a control host with an ordinary
certificate. Without those, the bundle checks still work, but every client probe would read
UNKNOWN, and the pack must not be shipped with made-up hosts.

## The format

`assets/incidents/<id>.conf`, one record per line, fields separated by `|`, `#` starting a
comment line. 7-bit ASCII with LF line endings: Windows PowerShell 5.1 reads files in the
ANSI code page, and macOS bash 3.2 reads lines without help. No field may contain `|`.

```text
id|<id>                                  the file name without .conf
name|<short name>                        in messages: "a listed <name> key", "the <name> fix"
title|<one line>                         printed by --list
as_of|<YYYY-MM-DD>                       the date the facts were last checked
reference|references/<id>.md             the sources, verification and platform notes
key|<SPKI SHA-256>|<cert name>|<SPKI>    one per distrusted key (repeat)
control|<host>                           ordinary certificate; proves the client can connect
path|<label>|<host>                      one per trust path (repeat; at least one)
version|<id>|<command>|<label>|<N.N.N>|<fix>  a tool judged by version (optional, repeat)
fixed|<slot>|<versions>                  first fixed releases named in fix hints (optional)
```

`key` lines come from `scripts/pack-keys.sh`, never by hand:

```bash
bash "<skill-dir>/scripts/pack-keys.sh" roots.pem impacted-intermediates.pem
```

It prints `key|<SHA-256 of the DER SubjectPublicKeyInfo>|<subject CN>|<that SPKI, base64>`
once per distinct key. The hash is what the checkers compare; the SPKI is what the bash
checker builds its search needles from, so a bundle is scanned in one pass instead of three
openssl runs per certificate.

`fixed` slots the checkers know: `node`, `python`, `certifi`, `pip`, `git-for-windows`,
`composer-ca-bundle`. A missing slot makes the hint say "a release with the <name> fix".

## Field rules

Both checkers enforce the same rules and refuse a pack that breaks one (exit 4), because a
pack's hosts reach the network and its commands reach the PATH. `tests/run.sh` feeds both a
set of malformed packs and fails if either accepts one.

| Field | Rule |
| --- | --- |
| id | equals the file name; lower-case letters, digits, hyphens |
| key hash | 64 upper-case hex digits, each listed once |
| key SPKI | base64 of a SubjectPublicKeyInfo (`SEQUENCE { SEQUENCE, BIT STRING }`, 16+ key bytes) |
| host | lower-case letters, digits, dots, hyphens; at least one dot; no port, path or user |
| path label | letters, digits, spaces, dots, hyphens; labels and hosts unique; control host differs |
| version command | letters, digits, `.`, `_`, `-`; not starting with `-` |
| minimum version | `N.N.N`, compared numerically field by field |
| record type | one of the ten above; anything else is refused, never ignored |

The checkers contact the control host and each path host on port 443 and nothing else. The
only way to point them elsewhere is the test hook `CA_TRUST_LOCAL_PORTS`, which always means
localhost.

## Adding a pack, step by step

1. **Collect the certificates.** Every distrusted root and intermediate, including every
   cross-sign: a key can sit in several certificates, and the pack lists keys. Prefer the
   disclosure's own published PEMs.
2. **Verify every key from two independent sources** before it goes in. For the first pack
   that meant: the disclosure's PEMs hashed locally, crt.sh's `spkisha256` for each root,
   the patched Homebrew `ca-certificates` formula's `EXCLUDED_SPKI_HASHES`, copies of the
   roots in bundles other software ships, and the intermediates' certificate hashes checked
   against the root program's bug. Also confirm that the fixed bundles (the patched certifi,
   curl's `cacert.pem`) hold none of the keys. Record each source in the reference.
3. **Add fixtures**: `tests/fixtures/<id>/listed-*.crt` with every listed certificate (keys
   from them must equal the pack's keys exactly), and `tests/fixtures/<id>/unlisted.crt`
   with nearby certificates that must stay trusted (sibling roots of the same CA, a common
   root). Name them `.crt`, not `.pem`.
4. **Write the pack**: `key` lines from `scripts/pack-keys.sh`, the control and one `path`
   per trust path, `version` records for tools that bundle roots in a binary, `fixed` slots
   for the hints.
5. **Check the test hosts by hand once**: each path host must present a chain with a listed
   key on a current leaf that names it (`openssl s_client -connect <host>:443 -showcerts`),
   and the control must open in a browser. A host that fails this makes every probe UNKNOWN.
6. **Write `references/<id>.md`**: what happened, the trust paths, the keys with their
   certificate hashes, how each was verified, the hosts, the patched versions with their
   date, and platform notes (what the OS stores do on their own).
7. **Run `bash tests/run.sh`**. The pack tests check that every pack has fixtures and a
   reference, that its keys equal its fixtures' keys, that each SPKI hashes to its key, that
   `pack-keys.sh` reproduces its key lines, and that both checkers catch every listed fixture
   certificate.
8. **Add the incident to `SKILL.md`'s pack list** and a CHANGELOG line.

## Retiring a pack

Keep a pack while machines may still carry the old bundles; distrust lingers in tools for
months after browsers move on. When the test hosts go away, every probe reads UNKNOWN: say
so in the reference and in `SKILL.md`, and keep the pack for its bundle checks
(`--bundle`, `--offline`) until its keys are gone from the bundles people still run.
