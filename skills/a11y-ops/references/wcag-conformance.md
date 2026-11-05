# WCAG, EN 301 549 and the Law

What standard applies to you, what it actually requires, and what a conformance
claim commits you to. Facts verified **2026-08-30** — dates and version numbers
in this area move, so re-check before quoting one to a client.

## Contents

- [The standards, in one paragraph](#the-standards-in-one-paragraph)
- [WCAG 2.2 — what changed from 2.1](#wcag-22--what-changed-from-21)
- [The European Accessibility Act](#the-european-accessibility-act)
- [ADA Title II (United States)](#ada-title-ii-united-states)
- [What a conformance claim actually says](#what-a-conformance-claim-actually-says)
- [Choosing a target](#choosing-a-target)
- [Cross-reference](#cross-reference)

---

## The standards, in one paragraph

**WCAG** is the technical standard, published by the W3C. **EN 301 549** is the
European harmonised standard that *incorporates* WCAG and adds non-web
requirements. **The EAA** and **ADA Title II** are laws that point at those
standards. So there is one body of technical criteria and several legal
instruments that make it enforceable in different jurisdictions.

| Level | What it means in practice |
|---|---|
| **A** | Baseline. Failing these excludes people outright |
| **AA** | **The legal target everywhere.** Every regime below requires AA |
| **AAA** | Not expected wholesale; W3C explicitly says AAA conformance is not required as a general policy |

## WCAG 2.2 — what changed from 2.1

WCAG 2.2 (October 2023) has **87 success criteria**. It added nine and removed
one. It is backwards-compatible: satisfying 2.2 satisfies 2.1.

| New in 2.2 | Level | What it requires |
|---|---|---|
| 2.4.11 Focus Not Obscured (Minimum) | **AA** | A focused element must not be *entirely* hidden by other content (sticky headers, cookie bars) |
| 2.4.12 Focus Not Obscured (Enhanced) | AAA | Not even partially hidden |
| 2.4.13 Focus Appearance | AAA | Minimum size and contrast for the focus indicator |
| 2.5.7 Dragging Movements | **AA** | Anything draggable needs a single-pointer alternative |
| 2.5.8 Target Size (Minimum) | **AA** | Interactive targets at least **24×24 CSS px**, with spacing exceptions |
| 3.2.6 Consistent Help | **A** | Help mechanisms appear in a consistent place across pages |
| 3.3.7 Redundant Entry | **A** | Don't make people re-enter information they already gave you |
| 3.3.8 Accessible Authentication (Minimum) | **AA** | No cognitive function test (puzzles, transcription) without an alternative |
| 3.3.9 Accessible Authentication (Enhanced) | AAA | As above, without the object-recognition exception |

**Removed: 4.1.1 Parsing.** It was obsoleted — modern browsers recover from
duplicate ids and malformed nesting, so it no longer mapped to real user harm.
Tools still reporting "4.1.1 failures" are out of date. (Duplicate ids remain a
genuine problem where they break `label`/`aria-*` association, which is why this
skill's scanner reports them under 4.1.2 instead.)

The three AA additions with real design consequences are **2.5.8** (target size
— it forces padding decisions across a whole component library), **2.4.11**
(sticky UI must not eclipse focus) and **3.3.8** (kills "type the characters
from this image" auth).

## The European Accessibility Act

The EAA became applicable on **28 June 2025** for new products and newly
published digital content. **2026 is the first full year national authorities
supervise against it**, and enforcement is expected to intensify through the year
as monitoring bodies staff up.

- **Standard:** EN 301 549 **v3.2.1**, which incorporates **WCAG 2.1 Level AA**
  in full. **v4.1.1 is expected during 2026 and moves to WCAG 2.2** — so building
  to 2.2 AA now is the cheaper path, not gold-plating.
- **Extraterritorial.** It applies to anyone offering products or services to
  consumers *in the EU*, regardless of where the business is established. "We're
  not an EU company" is not a defence.
- **Penalties** are set per member state and range roughly **€5,000 to
  €500,000**; Germany, for example, provides for up to €100,000 per violation.
- **Transitional:** service contracts concluded before 28 June 2025 must comply
  by **28 June 2027**.
- **An accessibility statement is part of the obligation**, not a nicety — see
  [`assets/accessibility-statement.template.md`](../assets/accessibility-statement.template.md).

## ADA Title II (United States)

**Check this one carefully — the dates moved recently and most published advice
is stale.** On **20 April 2026 the DOJ issued an interim final rule extending the
Title II compliance dates by one year**:

| Covered entity | Deadline |
|---|---|
| Public entities serving a population of **50,000 or more** | **26 April 2027** |
| Smaller entities and special district governments | **26 April 2028** |

The standard is **WCAG 2.1 Level AA**. The DOJ stated it "fully anticipates
implementing the regulation at the new deadline", which legal commentary reads as
a signal that enforcement follows the dates rather than slipping again.

Title II covers state and local government. **Title III** (private businesses as
places of public accommodation) has no equivalent regulation specifying WCAG, but
is litigated heavily on the same substance — so the practical target is identical.

## What a conformance claim actually says

Conformance is **per-page** (or per-process for a multi-step flow), and it is
all-or-nothing at the chosen level: **one failed Level AA criterion means the page
does not conform to AA.** There is no partial credit, no percentage score.

Consequences worth stating to a client before they ask for "a compliance badge":

- **A score is not a claim.** Tool output like "94% accessible" corresponds to
  nothing in the standard. Vendors sell it; the standard does not recognise it.
- **Third-party content still counts** where you control its inclusion — an
  embedded map, a chat widget, an ad slot.
- **Accessibility-overlay widgets do not confer conformance**, and have
  repeatedly failed in litigation. Treat a request for one as a signal that
  someone is looking for a shortcut, and explain the remediation path instead.
- **Conformance decays.** A page that conformed at launch does not conform after
  six months of CMS edits. The claim needs a review cadence attached.

## Choosing a target

For almost every project: **WCAG 2.2 Level AA**.

It satisfies the EAA today via 2.1 AA, satisfies it after EN 301 549 v4.1.1
lands, satisfies ADA Title II, and satisfies the UK Public Sector Bodies
Accessibility Regulations. Targeting 2.1 to save the nine extra criteria buys a
migration later at a worse moment.

## Cross-reference

- Running an actual audit → [audit-workflow.md](audit-workflow.md)
- The failures you will actually find → [common-failures.md](common-failures.md)
- Contrast ratios and colour maths → `color-ops`
- Icon and logo accessibility → `icon-ops`
