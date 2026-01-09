# Canvas TUI - Markdown Rendering Investigation

**Status:** Open
**Component:** `canvas-tui/src/hooks/useMarkdown.ts`
**Date:** 2026-01-09

---

## Problem Summary

Numbered lists in the canvas TUI markdown renderer exhibit intermittent rendering failures where:

1. Items are dropped (e.g., item 2 disappears)
2. Text from adjacent items merges (e.g., "integrationsrequesting")
3. Original markdown numbering appears instead of our renumbered output (showing "1, 3" instead of "1, 2, 3")

The bug is intermittent - identical code sometimes works, sometimes fails.

---

## Architecture

```
Content Flow:
┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐
│ Raw Markdown│───▸│ useMarkdown hook │───▸│ Rendered ANSI   │
└─────────────┘    └──────────────────┘    └─────────────────┘
                           │
                   ┌───────┴───────┐
                   ▼               ▼
           ┌─────────────┐  ┌─────────────┐
           │ Numbered    │  │ cli-markdown│
           │ Lists       │  │ (everything │
           │ (custom)    │  │  else)      │
           └─────────────┘  └─────────────┘
```

**Strategy:** Process content in sections. Detect numbered lists with regex, render them ourselves (to avoid cli-markdown bugs), delegate everything else to cli-markdown.

---

## The Bug

### Symptoms

When the bug manifests, the output shows:
```
1. Platform Scalability - Addressing the infrastructure bottlenecks...
3. Developer Experience - Improving our API...integrationsrequesting
```

Note:
- Item 2 ("Enterprise Features") is completely missing
- "requesting" (end of item 2's text) is merged with item 3
- Numbers are original (1, 3) not renumbered (1, 2, 3)

### What This Tells Us

Our custom numbered list handler renumbers items as 1, 2, 3 based on array index:
```typescript
numberedListItems.map((item, i) => `  ${i + 1}. ${renderInline(item)}`)
```

If output shows original numbers (1, 3), **cli-markdown is rendering the list, not our code.**

This means either:
1. Our regex isn't detecting the numbered list items
2. The numbered list is somehow being passed to cli-markdown

---

## Investigation

### Test 1: Regex Validation

Tested the detection regex against actual file content:

```javascript
const regex = /^(\s*)(\d+)\.\s+(.+)$/;
lines.forEach((line, i) => {
  const match = line.match(regex);
  console.log(`Line ${i+1}: ${match ? 'MATCH' : 'NO MATCH'}`);
});
```

**Result:** All 3 numbered list lines MATCH correctly.

### Test 2: Processing Logic in Isolation

Simulated the exact processing loop outside React:

```javascript
// ... full processing logic ...
console.log('FLUSH NUMBERED LIST, items:', numberedListItems.length);
```

**Result:** Shows "FLUSH NUMBERED LIST, items: 3" - all items captured correctly.

### Test 3: Full Flow Simulation

Ran the complete processing including cli-markdown calls:

```
=== AFTER POST-PROCESS ===
  1. **Platform Scalability** - Addressing bottlenecks
  2. **Enterprise Features** - Delivering compliance
  3. **Developer Experience** - Improving our API
```

**Result:** Works perfectly in isolation! All 3 items, correctly renumbered.

### Test 4: File Content Verification

Checked actual file for encoding issues:
```bash
cat -A email-draft.md  # Shows $ for line endings
xxd email-draft.md     # Shows hex bytes
```

**Result:** Clean LF line endings, no hidden characters, no blank lines between numbered items.

### Test 5: Compiled Output Verification

Verified the TypeScript compiled to correct JavaScript:
```bash
grep -A5 "flushNumberedList" dist/hooks/useMarkdown.js
```

**Result:** Compiled code matches source, includes the `\n` prefix fix.

---

## Key Observations

### The Debug String Mystery

The bug behavior changed based on what string we pushed to outputSections:

| Code | Behavior |
|------|----------|
| `outputSections.push('[DEBUG: N items]\n' + listOutput)` | **WORKS** |
| `outputSections.push('\n' + listOutput)` | **FAILS** (intermittent) |
| `outputSections.push(listOutput)` | **FAILS** |

The only difference is the string content. Having text before the newline somehow stabilizes the behavior.

### The Bullet Regex Correlation

The bug appeared/worsened after adding this regex:
```javascript
rendered = rendered.replace(/\n\n(\s*[•\-\*]\s)/g, '\n$1');
```

This regex should NOT affect numbered lists (matches `•`, `-`, `*` but not digits). Yet removing it seems to help.

---

## Hypotheses

### H1: Section Boundary Race Condition

When outputSections are joined, the string starting with `\n` might interact poorly with cli-markdown's output which may also end with newlines. The `\n{3,}` normalization could be collapsing something critical.

**Evidence:** Adding text before `\n` (debug string) prevents the issue.

### H2: cli-markdown State Bleeding

cli-markdown might have some internal state that persists between calls, causing content from one section to affect another.

**Evidence:** Processing works in isolation but fails in the app.

### H3: React useMemo Timing

The useMemo hook might be returning stale cached values, or the `width` dependency is causing unexpected re-renders that interact with the processing.

**Evidence:** Bug is intermittent despite identical code.

### H4: Regex Replacement Side Effects

The bullet-stripping regex, despite not matching numbered lists, might be causing side effects through JavaScript's regex engine state (lastIndex, etc.).

**Evidence:** Bug correlates with adding/removing this regex.

---

## Current State

The bullet-stripping regex has been removed. Testing needed to confirm if this resolves the numbered list issue.

If confirmed, we need an alternative approach for bullet list spacing that doesn't interfere with numbered lists.

---

## Recommended Next Steps

1. **Confirm current state works** - Test with bullet regex removed
2. **If working, isolate bullet regex issue:**
   - Test regex in isolation
   - Try alternative regex patterns
   - Consider post-processing bullets separately from numbered lists
3. **If still broken, add instrumentation:**
   - Log outputSections array contents
   - Log numberedListItems at flush time
   - Compare React render vs isolated execution
4. **Consider architectural changes:**
   - Process all lists (bullet + numbered) with custom renderer
   - Or use a different markdown library entirely

---

## Code Reference

**File:** `canvas-tui/src/hooks/useMarkdown.ts`

Key sections:
- Lines 57-73: Main processing loop with numbered list detection
- Lines 45-55: `flushNumberedList()` function
- Lines 83-84: Post-processing regex (bullet regex removed)

---

## Related Issues

- cli-markdown has known issues with numbered list rendering (drops/merges items)
- This is why we implemented custom numbered list handling in the first place
