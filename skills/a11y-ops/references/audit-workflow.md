# Running an Accessibility Audit

How to actually find the failures, in the order that finds the most for the least
effort — and an honest account of what each layer can and cannot detect.

---

## The uncomfortable number

**Automated tooling detects roughly 30–40% of WCAG failures.** That figure is
consistent across vendors and independent studies, and it is the single most
important fact in this file. Everything about how you plan an audit follows from
it:

- A green axe run is a **floor**, not a result.
- The majority of failures require a human judgement — is this alt text
  *meaningful*, is this focus order *logical*, does this error message *explain
  how to fix it*.
- Anyone selling "automated compliance" is selling the 30%.

So the workflow below spends automation on the cheap, mechanical failures and
reserves human time for what only humans can decide.

## The four passes, in order

### Pass 1 — Static source scan (seconds, in CI)

`scripts/scan-a11y.py src/` catches the mechanical failures before anything is
even built. Cheapest possible feedback, and it works on components in isolation
rather than needing a running page.

```bash
scan-a11y.py --min-severity serious src/     # exit 10 on findings
```

It reads *source*, so it sees less than a DOM-based tool: it cannot evaluate a
computed contrast ratio, a dynamically-set attribute, or anything a framework
renders conditionally. Treat it as a pre-filter that stops obvious defects
reaching the expensive passes.

### Pass 2 — Automated DOM scan (minutes, per route)

Run against the **rendered** page, which catches what source cannot: computed
contrast, ARIA relationships that resolve at runtime, generated markup.

| Tool | Shape | Use when |
|---|---|---|
| **axe-core** | library; the engine inside most others | The default. Embed in your e2e suite |
| **@axe-core/playwright** | Playwright integration | You already have Playwright (see `playwright-ops`) |
| **pa11y / pa11y-ci** | CLI + config, URL lists | Auditing a set of URLs outside a test suite |
| **Lighthouse** | bundled in Chrome DevTools | Quick single-page triage; its a11y score is *not* a conformance measure |
| **IBM Equal Access** | scanner + reports | When you need a report artefact for a client |

Wire it into the e2e suite rather than as a separate job — a route already has a
Playwright test that navigates and authenticates it, and duplicating that setup
in a standalone crawler is how a11y checks end up unmaintained.

**Scan states, not just pages.** The default state of a page is often its most
accessible one. Open the menu, trigger the error, expand the accordion, and scan
each — a modal's focus trap is invisible to a scan of the page behind it.

### Pass 3 — Keyboard (10 minutes per page, finds the most)

The highest-yield manual pass, and it needs no assistive technology. Put the
mouse down and:

1. **Tab through the whole page.** Does focus order follow the visual order?
2. **Is focus always visible?** Not just present — visible against its
   background, and not eclipsed by a sticky header or a cookie bar (2.4.11).
3. **Can you reach everything interactive?** Anything reachable by mouse must be
   reachable by keyboard (2.1.1).
4. **Can you get back out?** Open a modal, a date picker, a custom dropdown —
   does focus move in, stay in, and return to the trigger on close? A focus trap
   you cannot escape is a 2.1.2 failure and traps a keyboard user on the page.
5. **Does Escape close what it should?** Does Enter/Space activate what looks
   like a button?
6. **Is there a skip link**, and does it actually move focus (not just scroll)?

Almost every custom component fails at least one of these, and none of them show
up in an automated scan.

### Pass 4 — Screen reader (30+ minutes, finds the subtle ones)

Test with **one** screen reader properly rather than four badly. Pair them
correctly, because SR + browser combinations behave differently:

| Screen reader | Pair with | Platform |
|---|---|---|
| **NVDA** (free) | Firefox or Chrome | Windows — the highest-usage combination |
| **VoiceOver** (built in) | Safari | macOS / iOS |
| **JAWS** (paid) | Chrome | Windows enterprise |
| **TalkBack** (built in) | Chrome | Android |

What to listen for:

- Does each control announce a **name, a role and its state**? "Button" alone is
  a failure; "Delete item, button" is right.
- Do headings form a sensible outline when you navigate by heading?
- Are form errors **announced**, not just coloured red?
- Is dynamic content announced (live regions), and is it announced *once*?
- Does the alt text say what the image *means* here, not what it depicts?

## Where to spend limited time

If you have one hour, in this order:

1. **Keyboard pass on the primary conversion flow.** Highest failure density,
   highest business impact.
2. **Automated scan across all routes** to sweep the mechanical failures.
3. **Forms** — labels, error messages, required-field indication. Forms are where
   accessibility failures turn directly into lost revenue.
4. **Focus management in whatever is custom** — the bespoke dropdown, modal or
   tab set. Native elements are usually fine; the hand-rolled ones are not.

## Reporting a finding usefully

A finding that a developer cannot act on wastes everyone's time. Each one needs:

- **Where** — page URL plus a selector or component name.
- **What** — the criterion number *and* what a user actually experiences.
  "2.4.7 fails" is a citation; "keyboard users cannot see which control is
  focused in the nav" is a bug report.
- **Who it affects** — screen reader, keyboard-only, low vision, cognitive.
- **Severity** — blocker (cannot complete the task) vs serious vs minor. Not all
  Level A failures are equally harmful in context.
- **A suggested fix**, ideally the native element that removes the problem.

## Regression: keep it fixed

Fixing accessibility once and not gating it means paying for the audit again
next year.

- Put the static scan in the pre-commit or CI gate (exit 10 = findings).
- Add axe assertions to the e2e tests for the flows that matter.
- Treat a new component without keyboard support as an incomplete component,
  not a follow-up ticket.
- Re-audit on a cadence — conformance decays with every CMS edit.

## Cross-reference

- What standard applies and by when → [wcag-conformance.md](wcag-conformance.md)
- The specific failures and their fixes → [common-failures.md](common-failures.md)
- Wiring axe into Playwright → `playwright-ops`
- Contrast maths and palette checking → `color-ops`
