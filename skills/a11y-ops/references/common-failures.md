# The Failures You Will Actually Find

Ranked by how often they appear, with the fix that removes the class of problem
rather than the instance. Most of these have the same root cause: a native
element was replaced by a `<div>`, and everything the native element gave you for
free had to be rebuilt and wasn't.

## Contents

- [The one rule that prevents most of this](#the-one-rule-that-prevents-most-of-this)
- [1. Form fields without a programmatic label](#1-form-fields-without-a-programmatic-label) · [2. Errors that only exist in colour](#2-errors-that-only-exist-in-colour) · [3. Icon-only controls with no accessible name](#3-icon-only-controls-with-no-accessible-name)
- [4. Custom controls that are keyboard-dead](#4-custom-controls-that-are-keyboard-dead) · [5. Focus you cannot see, or cannot escape](#5-focus-you-cannot-see-or-cannot-escape) · [6. Headings used for size](#6-headings-used-for-size)
- [7. Images whose alt text is wrong rather than missing](#7-images-whose-alt-text-is-wrong-rather-than-missing) · [8. Link text that means nothing out of context](#8-link-text-that-means-nothing-out-of-context) · [9. ARIA that lies](#9-aria-that-lies)
- [10. Touch targets under 24×24 (2.5.8, new AA)](#10-touch-targets-under-2424-258-new-aa) · [11. Motion that cannot be stopped](#11-motion-that-cannot-be-stopped) · [12. Skipped structure](#12-skipped-structure)
- [Cross-reference](#cross-reference)

---

## The one rule that prevents most of this

**Use the native element.** `<button>`, `<a href>`, `<input>`, `<select>`,
`<details>` arrive with focusability, keyboard activation, correct role, state
announcement and platform conventions already handled. A `<div role="button"
tabindex="0">` needs all of that hand-written, and the hand-written version is
where the failures live.

The corollary — the **first rule of ARIA** — is that no ARIA is better than bad
ARIA. `role="button"` on a div is worse than a `<button>`, because it *claims* a
contract it does not fulfil.

## 1. Form fields without a programmatic label

The most common serious failure, and the most commercially expensive because it
sits on your conversion path.

```html
<!-- Broken: placeholder is not a label. It vanishes on input, fails contrast
     in most designs, and is ignored or double-announced by many screen readers -->
<input type="email" placeholder="Email address">

<!-- Correct -->
<label for="email">Email address</label>
<input type="email" id="email" autocomplete="email">

<!-- Correct when the design has no visible label (reconsider first) -->
<input type="search" aria-label="Search products">
```

`autocomplete` is not decoration: **1.3.5 Identify Input Purpose (AA)** requires
it on fields collecting personal data, and it materially helps users with motor
and cognitive impairments.

## 2. Errors that only exist in colour

```html
<!-- Broken: red border only. Invisible to colourblind and SR users -->
<input class="error">

<!-- Correct: programmatic state, a described-by message, and text -->
<label for="pw">Password</label>
<input id="pw" type="password" aria-invalid="true" aria-describedby="pw-err">
<p id="pw-err">Password must be at least 12 characters.</p>
```

**Say how to fix it, not that it broke.** "Invalid input" fails 3.3.3 Error
Suggestion; "Enter a date as DD/MM/YYYY" passes. And **1.4.1 Use of Colour**
means colour can never be the only carrier of meaning — pair it with text or an
icon shape.

## 3. Icon-only controls with no accessible name

```html
<!-- Broken: announced as "button" -->
<button><svg>…</svg></button>

<!-- Correct: name the CONTROL, keep the icon hidden -->
<button aria-label="Delete item">
  <svg aria-hidden="true" focusable="false">…</svg>
</button>
```

The counter-intuitive part: the SVG stays `aria-hidden` **even when the icon is
the only content**. A name on the icon *and* the button produces a double
announcement. (`icon-ops` owns this in depth.)

## 4. Custom controls that are keyboard-dead

```html
<!-- Broken: mouse-only. Not focusable, no keyboard activation, no role -->
<div class="btn" onclick="save()">Save</div>

<!-- Correct -->
<button type="button" onclick="save()">Save</button>
```

If you genuinely cannot use a `<button>`, the div needs `role="button"`,
`tabindex="0"`, **and** a key handler for both Enter and Space — plus
`aria-pressed`/`aria-expanded` if it has state. Four things instead of zero.

`type="button"` matters: a `<button>` inside a form defaults to `type="submit"`
and will submit it.

## 5. Focus you cannot see, or cannot escape

- **`outline: none` with no replacement** is the single most damaging line of CSS
  in accessibility. If you dislike the default ring, replace it:
  `:focus-visible { outline: 2px solid; outline-offset: 2px; }`.
- `:focus-visible` rather than `:focus` gives keyboard users a ring without
  showing one on mouse click — which is the reason people remove it.
- **Focus obscured (2.4.11, AA in 2.2):** a sticky header or cookie banner that
  covers the focused element fails, even though focus is technically visible.
  `scroll-margin-top` on focusable elements is the usual fix.
- **Focus traps:** a modal must move focus in on open, keep Tab inside while
  open, close on Escape, and **return focus to the trigger** on close. Missing
  the last step is the most common half-implementation.
- **Never `tabindex` above 0.** It overrides DOM order globally and the
  resulting tab sequence is unmaintainable. `0` and `-1` are the only values you
  need.

## 6. Headings used for size

```html
<h1>Page title</h1>
<h4>Because h4 looked right</h4>   <!-- fails 1.3.1 -->
```

Screen reader users navigate by heading; the levels are the document outline.
Size is a CSS decision. One `<h1>` per page, no skipped levels, and if the design
needs small-but-important text, style an `<h2>`.

## 7. Images whose alt text is wrong rather than missing

Missing alt is caught by every tool. *Wrong* alt is caught by none of them.

| Case | Correct alt |
|---|---|
| Decorative / repeats adjacent text | `alt=""` — **empty, not omitted** |
| Informative | What the image *conveys here*, not what it depicts |
| Image inside a link | Where the link goes |
| Chart or graph | The finding, with the data in an adjacent table |
| Logo linking home | The company name — never `alt="Acme logo"` |
| Text in an image | The text verbatim (and reconsider the image) |

Alt text is contextual: the same photograph needs different alt in a news story
and a shopping grid.

## 8. Link text that means nothing out of context

Screen reader users list links to navigate. A list of nine "Read more" entries is
useless. Make the link text describe its destination, or extend it with visually
hidden text — never with `title`, which is unreliable and mouse-only.

Also: **2.4.4** is failed by a bare URL as link text, and by two links with the
same text going to different places.

## 9. ARIA that lies

- `aria-label` on a non-interactive element (`<div>`, `<span>`) is widely ignored.
- `role="presentation"` on something interactive removes its semantics but not its
  behaviour.
- `aria-hidden="true"` on anything focusable creates a focusable element with no
  accessible name — a guaranteed 4.1.2 failure and one of the nastiest, because
  the element is still in the tab order.
- Live regions (`aria-live="polite"`) must exist in the DOM **before** the content
  arrives, or nothing is announced.
- `aria-expanded`, `aria-selected`, `aria-checked` must be **updated in JS**. A
  state attribute set once at render and never changed is worse than absent.

## 10. Touch targets under 24×24 (2.5.8, new AA)

Pad the *control*, not the icon:

```css
.icon-btn { display: inline-flex; place-items: center; min-width: 24px; min-height: 24px; padding: .5rem; }
```

24×24 CSS px is the AA minimum. 44×44 is the long-standing usability guidance and
is what mobile actually needs. Note the spacing exception: a small target can pass
if it has sufficient clear space around it.

## 11. Motion that cannot be stopped

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: .01ms !important;
    animation-iteration-count: 1 !important; transition-duration: .01ms !important; }
}
```

Anything auto-playing, blinking or scrolling for more than five seconds needs a
pause/stop/hide control (2.2.2). Carousels are the usual offender.

## 12. Skipped structure

- **No skip link** — keyboard users tab through the entire nav on every page.
  It may be visually hidden until focused, but it must move focus, not just scroll.
- **No landmarks** — use `<header>`, `<nav>`, `<main>`, `<footer>`. Exactly one
  `<main>`.
- **Missing `lang`** — the wrong speech synthesiser voice makes content
  unintelligible. Mark inline language changes with `lang` too.
- **No page `<title>`**, or the same title on every route: it is the first thing
  announced on navigation.

## Cross-reference

- Which of these are legally required and by when → [wcag-conformance.md](wcag-conformance.md)
- How to find them systematically → [audit-workflow.md](audit-workflow.md)
- Contrast ratios → `color-ops` · Icons and logos → `icon-ops`
