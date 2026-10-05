# INP: Interaction to Next Paint

INP replaced FID as the responsiveness Core Web Vital on 2024-03-12. It observes every
click, tap and key press during the whole visit and reports (close to) the **slowest**
one: the time from the input until the next frame is painted. Good is <= 200 ms, poor
is > 500 ms at p75. Scrolling and hovering are not interactions.

## Contents

- [The three phases](#the-three-phases)
- [Diagnose: INP is a field metric](#diagnose-inp-is-a-field-metric)
- [Fix by phase](#fix-by-phase)
- [Yielding to the main thread](#yielding-to-the-main-thread)
- [Framework and legacy-code notes](#framework-and-legacy-code-notes)
- [Gotchas](#gotchas)

## The three phases

```
input ──► input delay ──► processing duration ──► presentation delay ──► next paint
          main thread       your event handlers     style, layout, paint
          busy with         (all listeners for      of the resulting
          something else    this interaction)       frame
```

| Phase | Typical culprit | First lever |
|---|---|---|
| **Input delay** | Long tasks already running: hydration, tag managers, third-party scripts, timers | Break up / defer the work that was running |
| **Processing duration** | Handlers doing too much synchronously | Do the visual update first, yield, defer the rest |
| **Presentation delay** | Huge DOM, expensive style/layout, forced reflows | Shrink the DOM and the work the frame needs |

A **long task** is any main-thread task over 50 ms. Long tasks don't cause INP on their
own: an interaction that lands during one inherits its remaining time as input delay.

## Diagnose: INP is a field metric

A lab page load has no user, so it has no INP. Use the field to find **which
interaction** is slow, then reproduce that interaction in the lab.

1. **RUM attribution** (`web-vitals/attribution` `onINP`) gives `interactionTarget`
   (selector), `inputDelay`, `processingDuration`, `presentationDelay`, `loadState`
   (did it happen while the page was still loading?) and `longestScript` (the script,
   from Long Animation Frames, Chrome 123+). This usually names the culprit outright.
2. **Group by target + phase.** "Mobile menu toggle, input delay 400 ms, loadState
   `dom-content-loaded`" points at load-time JavaScript. "Filter checkbox, processing
   600 ms" points at the handler.
3. **Lab reproduction.** DevTools Performance panel with 4x CPU throttling: record,
   perform the interaction, read the interaction track and the long tasks under it.
   Lighthouse timespan mode reports INP and the `inp-breakdown-insight` for interactions
   you perform during the span.
4. **TBT as a proxy.** Lab Total Blocking Time (long-task time between FCP and
   interactive) correlates with input delay during load. It predicts problems; it does
   not measure INP.

## Fix by phase

### Input delay

| Cause | Fix |
|---|---|
| Large JS bundles evaluated at load | Code-split, defer non-critical modules ([javascript.md](javascript.md)) |
| Tag manager firing many tags at page load | Fire on `window.load` or after first interaction; audit and delete dead tags |
| Session replay, heatmaps, chat widgets | Load after interaction or idle; sample sessions instead of recording 100% |
| Consent manager blocking the main thread | Choose a lightweight one; load it async; never sync in `<head>` |
| `setInterval`/polling, carousels autoplaying | Pause offscreen; use `requestIdleCallback` for housekeeping |

### Processing duration

| Cause | Fix |
|---|---|
| Handler updates UI **and** does analytics, storage, network, validation | Paint first: apply the visual change, then `await yieldToMain()` and do the rest |
| Expensive work per keystroke (search-as-you-type, live filtering) | Debounce (150-300 ms); move filtering of large lists to a Web Worker |
| Several listeners on the same event (yours + a tag manager's click trigger) | They all run before the paint; keep third-party click listeners passive and cheap |
| Re-rendering a large component tree | Narrow the reactive update; virtualise long lists |
| Synchronous layout reads after writes (`offsetHeight` after a class change) | Batch reads before writes; Lighthouse 13 `forced-reflow-insight` flags it |

### Presentation delay

| Cause | Fix |
|---|---|
| DOM of thousands of nodes; a class toggle on `<body>` restyles everything | Reduce DOM size; scope state classes to the component |
| Rendering a big HTML string (`innerHTML`) on click | Render incrementally; paginate |
| Offscreen sections still rendered | `content-visibility: auto` + `contain-intrinsic-size` ([css.md](css.md)) |
| Layout-triggering animations started by the interaction | Animate `transform`/`opacity` |

## Yielding to the main thread

Yield inside long work so the browser can paint and handle input in between.

```js
// scheduler.yield(): Chrome/Edge 129+, Firefox 142+, not Safari (2026-10).
// Resumes ahead of other queued tasks; setTimeout is the universal fallback.
function yieldToMain() {
  if (globalThis.scheduler?.yield) return scheduler.yield();
  return new Promise((resolve) => setTimeout(resolve, 0));
}

button.addEventListener('click', async () => {
  openMenu();              // 1. the visual response the user is waiting for
  await yieldToMain();     // 2. let the frame paint
  trackMenuOpen();         // 3. everything else
  prefetchMenuContent();
});

// Long loops: yield on a time budget, not after every item (the overhead adds up).
async function processAll(items) {
  let deadline = performance.now() + 50;
  for (const item of items) {
    process(item);
    if (performance.now() > deadline) {
      await yieldToMain();
      deadline = performance.now() + 50;
    }
  }
}
```

## Framework and legacy-code notes

| Stack | INP lever |
|---|---|
| Vue 2 (end of life since 2023-12-31) | Deep reactivity on large objects is costly: `Object.freeze()` static lists; avoid watchers on big arrays; split huge components. Plan the move to Vue 3 (see `vue-ops`) |
| Vue 3 | `shallowRef` for large data; `v-memo`, `v-once` on static subtrees; async components for below-the-fold widgets |
| jQuery-era sites | Delegated handlers on `document` run for every click; scope them. Replace `.animate()` on layout properties with CSS transitions |
| Alpine.js / small islands | Usually cheap; INP problems come from the third parties beside them |
| GTM click triggers | "All Elements" click triggers attach work to every click; prefer specific triggers |

## Gotchas

| Gotcha | Why | Fix |
|---|---|---|
| INP fine on desktop, poor on mobile | Mobile CPUs are 3-5x slower; the same JS takes 3-5x longer | Test with 4x-6x CPU throttling, or on a mid-range Android |
| "TBT is 0 so INP is fine" | TBT covers load only; INP covers the whole visit | RUM is the only proof |
| Worst interaction is the cookie-banner "Accept" | Accepting fires every consent-gated tag at once | Stagger tag firing after consent; yield between them |
| `await fetch()` in a handler "yields" | Only after the synchronous part; code before the first `await` still blocks | Put the visual update before any heavy synchronous work |
| Long task attributed to "anonymous" script | Inline or eval'd code (often a tag manager's custom HTML tag) | Use `longestScript.entry.sourceURL` / `invoker` in RUM, then audit the tag |
