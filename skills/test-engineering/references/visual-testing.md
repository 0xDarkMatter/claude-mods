# Visual Testing with Chrome DevTools

Interactive visual checks during write mode, using browser tooling. **Policy lives in
profile.md** (when visual tests are worth having, and who may accept a new baseline: the diff
image in the PR at `standard`, a named human at `critical`). Visual regression is a change
detector: it proves no behaviour, so it never replaces a behavioural test of the same rule.

---

## Overview

`--visual` in write mode adds browser-based checks: real browser verification, accessibility
snapshots and visual regression baselines.

```bash
/test-engineering write src/pages/Login.tsx --visual
```

---

## How It Works

1. **Detects Chrome DevTools MCP availability** via `mcp__chrome_devtools__*` tools

2. **For each component/page:**
   - Launches browser with `mcp__chrome_devtools__navigate_page`
   - Takes accessibility snapshot with `mcp__chrome_devtools__take_snapshot`
   - Captures screenshot with `mcp__chrome_devtools__take_screenshot`
   - Tests interactions with `mcp__chrome_devtools__click`, `mcp__chrome_devtools__fill`

3. **Generates test documentation with:**
   - Visual regression baselines
   - Accessibility tree verification
   - Interactive element mapping

---

## Chrome DevTools MCP Tools

| Tool | Purpose |
|------|---------|
| `navigate_page` | Load component in browser |
| `take_snapshot` | Get accessibility tree for element refs |
| `take_screenshot` | Capture visual state |
| `click` | Test interactive elements |
| `fill` | Test form inputs |
| `list_console_messages` | Capture JS errors |
| `list_network_requests` | Verify API calls |
| `performance_start_trace` | Performance profiling |

---

## When to Use --visual

| Scenario | Recommended |
|----------|-------------|
| Component styling verification | Yes |
| Form interaction testing | Yes |
| Accessibility compliance | Yes |
| Unit testing pure functions | No |
| API integration tests | No |

---

## Example Output

```markdown
## Visual Test Results: LoginForm

### Accessibility Snapshot
- Form: role="form", aria-label="Login"
- Email input: role="textbox", name="email"
- Password input: role="textbox", name="password" (masked)
- Submit button: role="button", name="Log in"

### Screenshot
Captured: login-form-baseline.png

### Interactive Tests
- [PASS] Email field accepts input
- [PASS] Password field masks characters
- [PASS] Submit button triggers form validation
- [PASS] Error state displays for invalid email

### Console Errors
None detected

### Suggested Playwright Tests
[Generated code based on visual analysis]
```

---

## Claude-in-Chrome Integration

When the `mcp__claude-in-chrome__*` tools are available, `--visual` can also use:

| Tool | Purpose |
|------|---------|
| `read_page` | Get comprehensive accessibility tree |
| `find` | Locate elements by natural language |
| `computer` | Simulate real user interactions |
| `get_page_text` | Extract text content |

---

## Detection Logic

```bash
# Check for Chrome DevTools MCP
if available(mcp__chrome_devtools__take_snapshot); then
    echo "Chrome DevTools available - enabling visual testing"
fi

# Check for Claude-in-Chrome
if available(mcp__claude-in-chrome__read_page); then
    echo "Claude-in-Chrome available - enabling enhanced visual testing"
fi
```

---

## Fallback Chain

If Chrome DevTools is not available, `--visual` gracefully degrades:

```
Chrome DevTools MCP → Claude-in-Chrome → Playwright → Cypress → Manual testing
```

1. **Chrome DevTools**: Real-time browser control via MCP
2. **Claude-in-Chrome**: Enhanced accessibility and natural language queries
3. **Playwright**: Generate Playwright test code for manual execution
4. **Cypress**: Generate Cypress test code for manual execution
5. **Manual**: Output instructions for manual visual testing

---

## UI issues found in review

A UI issue raised by `/review` or an AI reviewer goes through triage mode first: the
regression test that closes it must fail on the unfixed code, and a visual baseline alone does
not count as that test.

---

## Output Artifacts

When `--visual` is used, the following artifacts may be created:

| Artifact | Location | Purpose |
|----------|----------|---------|
| Screenshots | `tests/__screenshots__/` | Visual regression baselines |
| Accessibility snapshots | `tests/__a11y__/` | A11y tree for comparison |
| Generated tests | `tests/visual/` | Playwright/Cypress test files |

---

## Integration with CI/CD

Visual tests can be run in CI with Chrome:

```yaml
# GitHub Actions example
- name: Visual Tests
  run: |
    npx playwright test --project=chromium
  env:
    CI: true
```

For Chrome DevTools MCP in CI, ensure the browser is launched in headless mode with remote debugging enabled.
