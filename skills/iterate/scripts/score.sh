#!/bin/bash
# Score iterate/SKILL.md on structural quality metrics.
# Output: a single integer score (higher = better, max ~100).
#
# This scorer is deliberately hard to max out.
# It rewards clarity, completeness, and economy of expression.

FILE="${1:-skills/iterate/SKILL.md}"
SCORE=0

if [ ! -f "$FILE" ]; then
  echo "0"
  exit 0
fi

CONTENT=$(cat "$FILE")
LINES=$(wc -l < "$FILE" | tr -d ' ')
WORDS=$(wc -w < "$FILE" | tr -d ' ')

# --- STRUCTURE (25 pts) ---

# Frontmatter fields (10 pts)
echo "$CONTENT" | head -1 | grep -q "^---" && {
  echo "$CONTENT" | grep -q "^name:" && SCORE=$((SCORE + 2))
  echo "$CONTENT" | grep -q "^description:" && SCORE=$((SCORE + 3))
  echo "$CONTENT" | grep -qi "triggers\? on:" && SCORE=$((SCORE + 2))
  echo "$CONTENT" | grep -q "^allowed-tools:" && SCORE=$((SCORE + 3))
}

# Required sections present (15 pts, 2.5 each - using 2+3 alternating)
for section in "## Setup" "## The Loop" "## Rules" "## Results" "## Adapt" "## Guard"; do
  echo "$CONTENT" | grep -qi "$section" && SCORE=$((SCORE + 2))
done
# Bonus for usage examples section
echo "$CONTENT" | grep -qi "## Usage\|## Example" && SCORE=$((SCORE + 3))

# --- LOOP COMPLETENESS (20 pts) ---
# All 8 steps of the loop referenced
for step in "REVIEW\|Review\|review" "IDEATE\|Ideate\|ideate" "MODIFY\|Modify\|modify" \
            "COMMIT\|Commit\|commit" "VERIFY\|Verify\|verify" "DECIDE\|Decide\|decide" \
            "LOG\|Log\|log" "REPEAT\|Repeat\|repeat"; do
  echo "$CONTENT" | grep -q "$step" && SCORE=$((SCORE + 2))
done

# Rollback strategy mentioned (4 pts)
echo "$CONTENT" | grep -q "git revert" && SCORE=$((SCORE + 2))
echo "$CONTENT" | grep -q "git reset\|fallback\|fall back" && SCORE=$((SCORE + 2))

# --- CLARITY (20 pts) ---

# Results.tsv example with actual data rows (5 pts)
tsv_rows=$(echo "$CONTENT" | grep -c "^[0-9].*	.*	.*keep\|^[0-9].*	.*	.*discard\|^[0-9].*	.*	.*baseline\|^[0-9].*	.*	.*crash")
if [ "$tsv_rows" -ge 3 ]; then
  SCORE=$((SCORE + 5))
elif [ "$tsv_rows" -ge 1 ]; then
  SCORE=$((SCORE + 2))
fi

# Domain adaptation table with 5+ examples (5 pts)
domain_rows=$(echo "$CONTENT" | grep -c "^|.*|.*|.*higher\|^|.*|.*|.*lower")
if [ "$domain_rows" -ge 5 ]; then
  SCORE=$((SCORE + 5))
elif [ "$domain_rows" -ge 3 ]; then
  SCORE=$((SCORE + 3))
fi

# Progress output format shown (5 pts)
echo "$CONTENT" | grep -q "Iteration [0-9]" && SCORE=$((SCORE + 3))
echo "$CONTENT" | grep -q "=== Iterate Complete\|summary" && SCORE=$((SCORE + 2))

# Inline config example with all 5 fields (5 pts)
example_fields=0
echo "$CONTENT" | grep -q "^Goal:" && example_fields=$((example_fields + 1))
echo "$CONTENT" | grep -q "^Scope:" && example_fields=$((example_fields + 1))
echo "$CONTENT" | grep -q "^Verify:" && example_fields=$((example_fields + 1))
echo "$CONTENT" | grep -q "^Direction:" && example_fields=$((example_fields + 1))
echo "$CONTENT" | grep -q "^Guard:" && example_fields=$((example_fields + 1))
if [ "$example_fields" -ge 5 ]; then
  SCORE=$((SCORE + 5))
elif [ "$example_fields" -ge 3 ]; then
  SCORE=$((SCORE + 2))
fi

# --- ECONOMY (20 pts) ---

# Line count: sweet spot 150-250 (10 pts)
if [ "$LINES" -ge 150 ] && [ "$LINES" -le 250 ]; then
  SCORE=$((SCORE + 10))
elif [ "$LINES" -ge 120 ] && [ "$LINES" -le 300 ]; then
  SCORE=$((SCORE + 6))
elif [ "$LINES" -ge 80 ] && [ "$LINES" -le 400 ]; then
  SCORE=$((SCORE + 3))
fi

# Word economy: under 2500 words (5 pts)
if [ "$WORDS" -le 1800 ]; then
  SCORE=$((SCORE + 5))
elif [ "$WORDS" -le 2500 ]; then
  SCORE=$((SCORE + 3))
elif [ "$WORDS" -le 3500 ]; then
  SCORE=$((SCORE + 1))
fi

# No TODO/FIXME/HACK/XXX markers (5 pts)
todo_count=$(echo "$CONTENT" | grep -ci "TODO\|FIXME\|HACK\|XXX")
if [ "$todo_count" -eq 0 ]; then
  SCORE=$((SCORE + 5))
fi

# --- HYGIENE (15 pts) ---

# Attribution to Karpathy (3 pts)
echo "$CONTENT" | grep -qi "karpathy" && SCORE=$((SCORE + 3))

# AskUserQuestion mentioned for missing config (3 pts)
echo "$CONTENT" | grep -q "AskUserQuestion" && SCORE=$((SCORE + 3))

# Bounded mode (Iterations: N) documented (3 pts)
echo "$CONTENT" | grep -q "Iterations:" && SCORE=$((SCORE + 3))

# "Never stop" / "never ask" principle (3 pts)
echo "$CONTENT" | grep -qi "never stop\|never ask" && SCORE=$((SCORE + 3))

# git add specific files warning (no -A) (3 pts)
echo "$CONTENT" | grep -q "git add -A\|never.*git add" && SCORE=$((SCORE + 3))

echo "$SCORE"
