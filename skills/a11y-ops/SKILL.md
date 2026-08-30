---
name: a11y-ops
description: "Web accessibility end to end - WCAG 2.2 conformance, legal obligations (EAA, ADA Title II), auditing with automated + keyboard + screen-reader passes, and the failures that appear on most sites. Triggers on: accessibility, a11y, WCAG, WCAG 2.2, AA conformance, EAA, European Accessibility Act, EN 301 549, ADA Title II, Section 508, accessibility audit, accessibility statement, VPAT, screen reader, NVDA, VoiceOver, JAWS, TalkBack, axe, axe-core, pa11y, Lighthouse accessibility, keyboard navigation, focus trap, focus visible, focus indicator, skip link, tab order, tabindex, aria, aria-label, aria-hidden, landmarks, alt text, form labels, error messages, colour contrast, target size, prefers-reduced-motion, inaccessible, disability, assistive technology, is my site accessible, accessibility compliance."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: color-ops, icon-ops, playwright-ops, testing-ops
---

# a11y-ops

Accessibility stopped being a quality preference and became a legal requirement
with dates attached. It is also, unhelpfully, a domain where the tooling
everyone reaches for finds well under half the problems — so the work is mostly
about knowing where automation stops.

## Helps with

"Is our site compliant?" — a question with a real answer that depends on which
jurisdiction, which standard version, and which deadline applies to that client.

An audit that needs to find real failures rather than produce a score. Vendor
"94% accessible" numbers correspond to nothing in the standard.

A component library where every custom control is mouse-only, because a `<div>`
replaced a `<button>` and nothing replaced what the `<button>` was doing.

Forms that lose conversions from screen reader and keyboard users: placeholders
used as labels, errors signalled only in red, no `autocomplete`.

`outline: none` shipped across a design system, leaving keyboard users with no
idea where they are.

A modal, dropdown or date picker that traps focus, or drops it, or never
returns it to the trigger.

Writing an accessibility statement that is honest enough to be defensible
rather than an overclaim that creates its own liability.

Wiring accessibility into CI so a fix stays fixed instead of being re-bought
at the next audit.

## The two things that decide everything

**1. Automated tooling finds roughly 30–40% of WCAG failures.** Every plan
follows from this. A green axe run is a floor, not a result — the rest needs a
keyboard and a human. Anyone selling automated compliance is selling the 30%.

**2. Use the native element.** `<button>`, `<a href>`, `<input>`, `<select>`,
`<details>` arrive with focusability, keyboard activation, correct role and
state announcement already handled. Almost every failure in the catalogue comes
from replacing one with a `<div>` and rebuilding a fraction of what was lost.
Its corollary is the first rule of ARIA: **no ARIA beats bad ARIA**, because
`role="button"` claims a contract a div does not fulfil.

## Which standard, and by when

Target **WCAG 2.2 Level AA** for essentially every project. It satisfies every
regime below, and building to 2.1 to skip nine criteria just buys a migration
at a worse moment.

| Regime | Standard | Status (verified 2026-08-30) |
|---|---|---|
| **EAA** (EU) | EN 301 549 v3.2.1 → WCAG 2.1 AA | Applicable since 28 Jun 2025; **2026 is the first full supervision year**. v4.1.1 expected 2026 moves it to **WCAG 2.2**. Fines ~€5k–€500k |
| **ADA Title II** (US) | WCAG 2.1 AA | **Deadlines extended 20 Apr 2026**: 26 Apr **2027** (pop ≥50k), 26 Apr **2028** (smaller) |
| **UK PSBAR** | WCAG 2.2 AA | Public sector; accessibility statement required |

**The EAA is extraterritorial** — it applies to anyone offering services to
consumers in the EU regardless of where the business sits. And conformance is
**per-page and all-or-nothing**: one failed AA criterion means the page does not
conform. There is no partial credit and no percentage.

Full detail, the nine criteria new in WCAG 2.2, and what a conformance claim
commits you to → [`references/wcag-conformance.md`](references/wcag-conformance.md).

## Workflow — four passes, cheapest first

### 1. Static source scan (seconds, in CI)

```bash
scripts/scan-a11y.py src/                          # exit 10 = findings
scripts/scan-a11y.py --min-severity serious src/
scripts/scan-a11y.py --json src/ | jq '.data[] | select(.severity=="critical")'
```

Catches the mechanical failures in HTML/JSX/Vue/Svelte/Astro source before
anything renders: missing alt, unlabelled inputs, placeholder-as-label,
icon-only controls with no name, click handlers on non-interactive elements,
positive `tabindex`, heading skips, `aria-hidden` on focusable elements,
untitled iframes, unmuted autoplay, duplicate ids.

Exit codes: `0` clean · `2` usage · `3` path missing · `5` nothing scannable ·
`10` findings. It reads *source*, so it cannot see computed contrast or
conditionally-rendered markup — it is a pre-filter, not the audit.

### 2. Automated DOM scan (minutes, per route)

Run **axe-core** against the rendered page — ideally inside the Playwright suite
you already have, so authentication and navigation aren't rebuilt in a separate
crawler (`playwright-ops`). Alternatives: `pa11y-ci` for URL lists, Lighthouse
for quick triage.

**Scan states, not just pages.** Open the menu, trigger the error, expand the
accordion. A modal's focus trap is invisible to a scan of the page behind it.

### 3. Keyboard pass (10 minutes, highest yield)

Put the mouse down. Tab the whole page: is focus order logical, is the indicator
always *visible* and not eclipsed by a sticky header (2.4.11), is everything
mouse-reachable also keyboard-reachable, can you escape every modal and does
focus return to the trigger, does the skip link move focus rather than just
scroll?

Nearly every custom component fails one of these, and none of them appear in an
automated scan.

### 4. Screen reader pass (30+ minutes)

Test **one** combination properly: NVDA + Firefox on Windows, or VoiceOver +
Safari on macOS. Listen for name, role and state on every control; a sensible
heading outline; errors that are announced; alt text that says what the image
*means here*.

Tool comparison, what to test in what order, and how to write a finding a
developer can act on → [`references/audit-workflow.md`](references/audit-workflow.md).

## The failures you will actually find

Ranked by frequency, with fixes that remove the class rather than the instance —
form fields without programmatic labels, errors carried only in colour,
icon-only controls with no name, keyboard-dead custom controls, `outline: none`,
focus traps, headings chosen for size, wrong-rather-than-missing alt text,
meaningless link text, ARIA that lies, targets under 24×24 (2.5.8), unstoppable
motion, missing skip links and landmarks →
[`references/common-failures.md`](references/common-failures.md).

Three worth knowing before you read it:

- **`aria-hidden="true"` on anything focusable** creates a focusable element
  with no accessible name — a guaranteed 4.1.2 failure, still in the tab order.
- **`tabindex` above 0** overrides DOM order globally. `0` and `-1` are the only
  values worth using.
- **A live region must exist in the DOM before the content arrives**, or nothing
  is announced.

## Accessibility statements

Publishing one is part of the EAA obligation, not a nicety. Start from
[`assets/accessibility-statement.template.md`](assets/accessibility-statement.template.md).

**Do not overclaim.** A statement is a written representation about the product,
so an undisclosed known failure is a worse problem than the failure. "Partially
conformant" with a listed issue and a remediation date is a normal, defensible
position; "fully conformant" without an audit is not.

## What this skill doesn't cover

- **Contrast ratios and palette maths** (WCAG 1.4.3, APCA) → `color-ops`
- **Icon and logo specifics** — the two-case naming rule, target size for
  icon-only controls → `icon-ops`
- **Wiring axe into a browser test suite** → `playwright-ops`
- **Native mobile accessibility** (UIKit/Android APIs) — different platform APIs
- **Legal advice.** This encodes standards, dates and obligations as published;
  a compliance decision with money attached needs a lawyer, not a skill.

## Cross-references

| When | Use |
|---|---|
| Checking a palette meets 1.4.3 / 1.4.11 | `color-ops` |
| Naming icon-only controls, logo `alt` | `icon-ops` |
| Automating the DOM scan in e2e | `playwright-ops`, `testing-ops` |
| The component library needs rebuilding around native elements | `refactor-ops` |

## References

- [`references/wcag-conformance.md`](references/wcag-conformance.md) — the
  standards map: WCAG 2.1 vs 2.2 with all nine new criteria and why 4.1.1 was
  removed; EAA dates, penalties and extraterritorial reach; the extended ADA
  Title II deadlines; and what a conformance claim actually commits you to
  (per-page, all-or-nothing, overlays don't count). Load before quoting a
  deadline or a target to a client.

- [`references/audit-workflow.md`](references/audit-workflow.md) — the four
  passes with what each can and cannot detect, the axe/pa11y/Lighthouse
  comparison, screen-reader/browser pairings, where to spend a single hour, how
  to report a finding usefully, and regression gating. Load when running an audit.

- [`references/common-failures.md`](references/common-failures.md) — the twelve
  recurring failures with before/after code and the class-level fix. Load when
  remediating, or when reviewing a component library.

## Scripts

- `scripts/scan-a11y.py` — static pre-flight for high-confidence WCAG failures
  in HTML/JSX/Vue/Svelte/Astro source. `--min-severity`, `--rule` to filter,
  `--json` envelope, exit 10 as the CI domain signal. Deliberately conservative:
  a linter that cries wolf gets muted, and a muted linter is worse than none.

## Assets

- `assets/accessibility-statement.template.md` — heavily commented statement
  template covering conformance status, known issues, assessment method,
  compatibility, feedback route and the enforcement procedure per jurisdiction.
