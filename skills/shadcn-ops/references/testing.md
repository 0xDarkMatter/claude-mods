# Testing shadcn/ui components

What is specific to testing shadcn/ui code: queries that survive a restyle, overlays in
portals, the browser APIs jsdom lacks, and what only a real browser can check. Test
strategy (what deserves a test, proving it can fail, mocking, CI cost) is test-engineering's
subject; end-to-end suites are playwright-ops'.

## Setup

Vitest with `@testing-library/react`, `@testing-library/user-event` and
`@testing-library/jest-dom`, in a jsdom environment, with the app's `@/` alias resolved the
way Vite resolves it. Drive components with `user-event`, which fires the whole event
sequence a real click or keypress makes; `fireEvent` fires one event, and menus and selects
that open on pointer events stay shut.

## Query by role and accessible name

- `screen.getByRole("button", { name: "Open menu" })`, `getByRole("dialog", { name:
  "Invite a teammate" })`. A dialog's name is its `DialogTitle`, one more reason every
  Dialog, Sheet and Drawer has one. Testing Library ranks `getByRole` first and test ids
  last.
- Dialogs, sheets, popovers, menus, select and combobox lists, tooltips and toasts render
  in a portal on `document.body`, outside the `container` that `render` returns. Query them
  through `screen` (bound to `document.body`), never `within(container)`.
- Overlays mount after the click: `await user.click(trigger)`, then
  `await screen.findByRole("menu" | "listbox" | "dialog" | "alertdialog")`.
- Fall back to `data-testid` only when no role and name identify the element.

```tsx
test("delete asks before it deletes", async () => {
  const user = userEvent.setup()
  const onDelete = vi.fn()
  render(<UserRowActions onDelete={onDelete} />)
  await user.click(screen.getByRole("button", { name: "Open menu" }))
  await user.click(await screen.findByRole("menuitem", { name: "Delete" }))
  const confirm = await screen.findByRole("alertdialog")
  expect(onDelete).not.toHaveBeenCalled()
  await user.click(within(confirm).getByRole("button", { name: "Delete user" }))
  expect(onDelete).toHaveBeenCalledOnce()
})
```

## jsdom gaps: diagnose, then shim

jsdom implements no layout and several browser APIs that primitives call. Don't paste a
block of polyfills up front: run the test, read the error, add the one shim it names to the
setup file, and note which component needed it.

| Error text | jsdom lacks | Seen with |
|---|---|---|
| `target.hasPointerCapture is not a function` | pointer capture (jsdom#4271, open) | opening a Radix Select (radix-ui/primitives#1822) |
| `scrollIntoView is not a function` | `Element.scrollIntoView` (jsdom#1695, open) | Radix Select highlighting an item (#1822); lists that scroll the active item into view |
| `ResizeObserver is not defined` | `ResizeObserver` (jsdom#3368, open) | anything that measures itself, such as a chart's responsive container |
| `window.matchMedia is not a function` | `matchMedia` (jsdom#3522, open) | the Sidebar, through `useIsMobile` in `hooks/use-mobile.ts` |

```ts
// vitest.setup.ts: add each line only after a test fails with its error
import "@testing-library/jest-dom/vitest"

Element.prototype.hasPointerCapture ??= () => false
Element.prototype.setPointerCapture ??= () => {}
Element.prototype.releasePointerCapture ??= () => {}
Element.prototype.scrollIntoView ??= () => {}
globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} }
window.matchMedia ??= (query) => ({ matches: false, media: query, onchange: null,
  addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {},
  dispatchEvent: () => false })
```

- **React Aria** documents its own helpers: `installPointerEvent()` for long press,
  `installMouseEvent()` plus a mocked `getBoundingClientRect` for dragging sliders, running
  pending timers inside `act` after interactions when fake timers are on, and the pattern
  testers in `@react-aria/test-utils` (a release candidate).
- **Base UI** publishes no list of jsdom gaps that we found (unverified): diagnose from the
  error text the same way.
- A shim only stops the crash. Sizes and positions are all 0 in jsdom, so placement,
  collision handling, charts, virtualised lists, `Resizable` and `scroll-fade` can't be
  verified there.

## Real-browser runs

Run in a real browser what jsdom can't show: focus moving into a Dialog, Sheet or
AlertDialog and back to the trigger, Escape and outside-click dismissal, arrow keys through
menus and lists, popover placement, toast stacking, charts, and anything animated. Vitest
Browser Mode runs the same component tests in a browser (`browser.enabled`, a provider such
as `@vitest/browser-playwright`, optionally `vitest-browser-react`). Whole user flows
(sign in, create, edit, delete across pages) are Playwright end-to-end tests: playwright-ops.

Sources: testing-library.com/docs/queries/about; react-aria.adobe.com/testing;
vitest.dev/guide/browser; the jsdom README (no layout or rendering) and jsdom issues 1695,
3368, 3522 and 4271;
github.com/radix-ui/primitives issue 1822; the shadcn-ui/ui registry sources for
`use-mobile.ts` and `chart.tsx`. Checked 2026-11-10.
