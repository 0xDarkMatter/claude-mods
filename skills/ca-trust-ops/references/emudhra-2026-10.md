# Incident pack: eMudhra, October 2026

The facts behind `assets/incidents/emudhra-2026-10.conf`, as read on 2026-10-26. The
disclosure site changes daily, so check it before quoting a patched version.

## Contents

- What happened
- The two trust paths
- The listed keys
- How each key was verified
- Test hosts
- Patched versions
- Platform notes
- Changing this pack

## What happened

Eight eMudhra intermediate CA keys were recoverable from their public certificates
([Mozilla bug 2083449](https://bugzilla.mozilla.org/show_bug.cgi?id=2083449)). Browsers
block them; command-line tools and language runtimes that carry their own CA bundle may
not. The disclosure site is [emudhra.we-have-a-problem.com](https://emudhra.we-have-a-problem.com/)
([source](https://github.com/galadran/we-have-a-problem.com)).

## The two trust paths

The six TLS intermediates (`EM DV/OV/EV TLS CA - G3B` and `- G3C`) and two code-signing
intermediates (`EM OV CS CA - G3B` and `- G3C`) were each issued twice, so every compromised
key sits in two certificates:

| Path | Chain | Trusted by |
| --- | --- | --- |
| emSign | intermediate, issued by `emSign Root TLS CA - G3` (or `emSign Root CS CA - G3`), which `emSign ECC Root CA - G3` cross-signs | every bundle that holds `emSign ECC Root CA - G3`: Apple, Mozilla-derived bundles before their fix (certifi, Node, curl's bundle, Composer's ca-bundle, distribution `ca-certificates`), Git for Windows; Microsoft also includes the two `Root ... G3` certificates |
| AAA | the same intermediate key, cross-signed by Sectigo's `AAA Certificate Services` | Apple, Microsoft, and older Mozilla-derived bundles: Mozilla and Chrome have removed `AAA Certificate Services`, but certifi 2025.1.31, Debian and Ubuntu bundles still carried it |

A check of only one path misses the other. Removing `emSign ECC Root CA - G3` alone, as the
disclosure's first macOS step does, leaves the AAA path open; a test of only the AAA host
passes a machine whose emSign path is open. So the pack names two `path` hosts.

The other emSign roots (`emSign Root CA - G1`, `- C1`, `emSign ECC Root CA - C3`) are
unaffected and stay in patched bundles. `tests/fixtures/emudhra-2026-10/unlisted.crt` holds
them (with ISRG Root X1), and the suite fails if any of them is listed.

## The listed keys

SHA-256 of the DER `SubjectPublicKeyInfo`. Matching the key, not the certificate, catches
both certificates of each intermediate and any re-issued copy of a root.

| SPKI SHA-256 | Certificate | Certificate SHA-256 |
| --- | --- | --- |
| `8D417DB2DD8BF5E3084D1E3F196D583849D81BDD4C00C70B9D39369E96B8C782` | emSign ECC Root CA - G3 | `86A1ECBA...36BBE6B` |
| `BD153ED7B0434F6886B17BCE8BBE84ED340C7132D702A8F4FA318F756ECBD6F3` | AAA Certificate Services | `D7A7A0FB...A699EF4` |
| `C619E4780ED8E0ABEDA24AD732567DE4383A7EA941338F6D1A7D1B49AC792FE9` | emSign Root TLS CA - G3 | `7DD78D5F...746ED8D` |
| `0A6C2B2CA5B364207954171987AC9D2178561569D8205457E77CA90C32EDE282` | emSign Root CS CA - G3 | `F2EDAAFF...ABA34A5` |
| `EBED6475C2C2D80FCB199F3FE8DD6E6B3CE60B77EB15D4E42C3DEC0C6F5B5105` | EM DV TLS CA - G3B | `42C4ACCD...8BA1493`, cross-sign `45A883F3...6FCDDBE` |
| `43BFFA19D6EF651451F6841E019931E96F6F2EAEFF28AB4B6F1CE4576DE2717B` | EM OV TLS CA - G3B | `98B89662...833BC25B`, cross-sign `5F1DED4D...BD832699` |
| `E0254C7FCDC265E2F0F8A428DABB75AB4AE039B4872D62F5EE57F0877D5A8A41` | EM EV TLS CA - G3B | `E7568FE6...84333838`, cross-sign `579480AE...F3199512` |
| `49DD353DC2B919A3770645117D0E60C16115E7D1BC259EEFE734B00EA434FE5F` | EM DV TLS CA - G3C | `0164D7CE...0934D19`, cross-sign `62B7F986...9B02E72` |
| `63ECEFEE431D49523BC1136C4E72D0206A477086CAF606CD5CF025686C109CF8` | EM OV TLS CA - G3C | `CB6E1516...F9C7C3F`, cross-sign `7485B51C...9DE9489` |
| `5C0660A2B164910D8FF589C18E14552E9E0EC237DCEFE2CB736D41A4811F81A0` | EM EV TLS CA - G3C | `432EC25F...D0261F3`, cross-sign `FD9D5C2D...F07021F` |
| `EC4FFA1AD0AC88081314B7AAFFEF6A91F97CD57291BB5BA686C5415F5EB4F6B6` | EM OV CS CA - G3B (code signing) | `9E39DE28...DB067B4`, cross-sign `A496E23A...D01C2D8` |
| `92C063D67E8F14DB71D288E11266FFDAF69CBF115F7BAB14F3BC2F68D25E0E30` | EM OV CS CA - G3C (code signing) | `4B2460A4...4C630B1`, cross-sign `84112972...615E1FD` |

A certificate's SHA-256 is not its SPKI hash. A list that puts certificate hashes where key
hashes belong matches nothing.

## How each key was verified

Each key comes from at least two independent sources, as `incident-packs.md` requires:

- **Root keys**, from four sources that agree: the PEMs in the disclosure's
  [roots.json](https://emudhra.we-have-a-problem.com/roots.json), hashed locally with
  `openssl`; the `spkisha256` link on each root's [crt.sh](https://crt.sh/) page; the
  `EXCLUDED_SPKI_HASHES` of Homebrew's patched
  [ca-certificates formula](https://github.com/Homebrew/homebrew-core/blob/d02b8762f4a29859c47a635a0d2683223fea9812/Formula/c/ca-certificates.rb)
  (AAA, emSign Root TLS CA - G3, emSign ECC Root CA - G3); and copies of
  `AAA Certificate Services` and `emSign ECC Root CA - G3` in bundles shipped by other
  software (botocore, Git for Windows 2.49).
- **Intermediate keys**, from the PEMs in the disclosure's
  [impacted-intermediates.json](https://emudhra.we-have-a-problem.com/impacted-intermediates.json),
  hashed locally, whose certificate SHA-256s equal the 16 that Mozilla bug 2083449 lists
  (comments 1, 2 and 10).
- **Fixed bundles hold none of the 12**: certifi 2026.10.19 (120 certificates) and curl's
  `cacert-2026-10-20.pem` (118), hashed certificate by certificate.

The fixtures in `tests/fixtures/emudhra-2026-10/` are those certificates:
`listed-roots.crt` (4), `listed-intermediates.crt` (8, issued by eMudhra),
`listed-cross-signs.crt` (8, issued by Sectigo), and `unlisted.crt` (ISRG Root X1 and three
unaffected emSign roots, from certifi 2026.10.19).

## Test hosts

The disclosure site serves a leaf from each compromised intermediate:

| Host | Pack record |
| --- | --- |
| `dv-g3b-emudhra.we-have-a-problem.com` | `path` emSign |
| `dv-g3b-aaa-emudhra.we-have-a-problem.com` | `path` AAA |
| `emudhra.we-have-a-problem.com` | `control`: an ordinary certificate, so a client that cannot open it proves nothing |

It also serves the other eleven intermediates and two chains never logged to Certificate
Transparency (`dv-g3b-noct-emudhra`, `dv-g3b-aaa-noct-emudhra`). The pack skips those: one
leaf per path proves trust in the path, and the clients the checker tests do not enforce CT.
The site's servers count successful connections per User-Agent
([statistics](https://statistics-emudhra.we-have-a-problem.com/)); the checker sends
`ca-trust-ops/1`.

## Patched versions

From the disclosure's "Who has patched?" tables on 2026-10-26. The pack's `version` and
`fixed` records carry the rows the checker uses.

| Software | Patched in |
| --- | --- |
| Homebrew ca-certificates | 2026-09-25_1 |
| Debian ca-certificates | 20250419~deb12u2, 20250419+deb13u1, 20260816+nmu1 |
| Ubuntu ca-certificates | 20260816ubuntu0.22.04.1, .24.04.1, .26.04.1, .26.10.1 |
| Alpine ca-certificates | 20261020-r0 |
| Fedora ca-certificates | 2026.2.92_v9.0.319 |
| RHEL ca-certificates | -81.3.el8_10, -90.3.el9_8, -100.3.el10_2 of 2026.2.92_v9.0.319; RHEL 7 pending |
| Python certifi | 2026.10.19 |
| pip | 26.2.2 |
| uv | 0.13.5 |
| Python | 3.13.17, 3.14.9, 3.15.1 |
| Node.js | 22.23.4, 24.22.1, 26.12.1 |
| Git for Windows | 2.56.0.3 |
| Claude Code | 2.1.303 |
| Deno | 2.9.8 |
| Bun | 1.4.4 |
| Composer ca-bundle | 1.4.16, 1.6.0 |
| curl CA bundle | 2026-10-20 |

## Platform notes

**macOS.** Apple blocks the certificates in its own networking and security frameworks, so
in Safari and most apps, since 22 October ("on Apple products since the 22nd", disclosure
page). The checker does not test that store. `/etc/ssl/cert.pem`, which `/usr/bin/curl`,
LibreSSL and Apple's `python3` read, had no fix on 2026-10-26; Apple has
[said](https://support.apple.com/en-us/149555) a future macOS update will change it, and
that an update may restore the file meanwhile. The disclosure offers two workarounds:

- **Option A**: export `SSL_CERT_FILE` and `CURL_CA_BUNDLE` pointing at Homebrew's patched
  bundle in `~/.zshrc`, and point git at it (`git config --global http.sslCAInfo`). The
  shell's `apple-curl`, `apple-python3` and `git` lines turn PASS, but background jobs and
  apps started outside the shell are not covered.
- **Option B**: remove both roots from `/etc/ssl/cert.pem`. It needs admin rights and a
  macOS update undoes it until Apple ships its fix, so re-run the checker after every update.

The `apple-cert-pem` line stays FAIL until both roots are gone from the file.

**Windows.** Microsoft blocks the certificates through automatic certificate trust list
updates (from 20 October), which reach .NET, Schannel `curl.exe` and git's Schannel backend:
the `windows-store` and `windows-curl` lines. Python's `urllib` on Windows loads the Windows
root store into OpenSSL, which does not apply that block, so an unpatched Python reads FAIL
on a patched Windows. That is real, not a checker bug: update Python (or certifi, for code
that uses it).

## Changing this pack

The keys live in `assets/incidents/emudhra-2026-10.conf` and, as certificates, in
`tests/fixtures/emudhra-2026-10/`. Change both in one commit, re-verify each new key from
two sources as above, print the new key lines with `scripts/pack-keys.sh`, and run
`bash tests/run.sh`, which fails when the pack's keys differ from the fixtures' keys. The
general procedure is in `incident-packs.md`.
