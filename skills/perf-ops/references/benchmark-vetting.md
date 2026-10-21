# Benchmark Vetting

Run through these before a measured figure is believed, quoted or used to decide anything: a
before/after delta, a regression claim, a throughput or latency figure, a pick between
libraries or settings, or the metric an `iterate` loop keeps or discards on. Answer each from
a run, not from reading the code. A number that fails a question is not wrong yet, only unexplained, and an unexplained
number does not go out as a claim.

Ideas adapted from pstack's benchmark checklist (MIT, github.com/cursor/plugins), restated.

## Contents

- [When one run is enough](#when-one-run-is-enough)
- [Before the first run](#before-the-first-run)
- [The seven questions](#the-seven-questions)
- [Verdicts](#verdicts)
- [With iterate and evals](#with-iterate-and-evals)

## When one run is enough

A rough estimate the user explicitly asked for may rest on a single run. Even then, check
errors (question 4) and work done (question 7), and label the figure single-run. Picking
between alternatives always gets the full list.

## Before the first run

- **Draft the sentence you hope to publish** before measuring: metric, percentile, dataset,
  unit ("p95 of /search drops 20% on the 1M-row fixture"). Every question below is checked
  against that sentence, not a general impression.
- **Read the harness.** Know what sits inside the timed region, what it counts, and what it
  discards.
- **Keep both versions runnable at once**: two build outputs, or a second git worktree. Timing
  every "before" run and then every "after" run lets machine drift choose the winner.
- **Check the machine is quiet** (the T1 system baseline in SKILL.md). If background load
  can't be stopped, alternate the two sides so each absorbs it equally, and note the
  contention in the write-up.

## The seven questions

1. **What limits it?** Name the bound: a core, a lock, disk, network, a pool size, or the
   client generating load (a saturated client means you benchmarked the client). Find it with
   a profiler or system counters in a throwaway run, never the one you quote, since profiling
   overhead distorts timing; then trace the hot spot back to the code
   ([cpu-memory-profiling.md](cpu-memory-profiling.md)).
   Without a named bound the number has no explanation and may be timing something else
   entirely. When a change leaves the number flat, the bottleneck is usually elsewhere: locate
   it before writing the change off.
2. **Were both sides tuned equally?** Give both production conditions: optimised builds, real
   flags and environment variables, matching pool, batch and transaction sizes, cache state
   like production's, identical versions and input data. One side on defaults turns the test
   into a settings comparison rather than a code comparison. A bottleneck that is a setting (an
   unoptimised build, an absent index, autocommit on every insert, a pool of one) marks that
   side untuned: fix it and rerun, or declare no winner. Narrowing the claim to "as configured
   today" does not rescue a choice of what to adopt, because whoever adopts it will tune it.
3. **Does it beat a physical limit?** Do the arithmetic. Check throughput against what the disk
   or link can carry, request rate times CPU cost per request against the cores you have, and
   the time saved against how long the changed code ran in the first place: a step that is 20%
   of the run can buy at most a 25% speedup (Amdahl's law). Beating physics means the timer
   caught something other than the job: a warm cache, an empty code path, a broken harness.
4. **Were errors, cache hits or skipped work hidden?** Count failures, non-success responses,
   timeouts and retries, and verify the results are right, since a wrong answer can arrive
   quickly. Fast rejections flatter throughput, retries pad latency, and a cache warm on one
   side only flatters that side. If the harness prints no error count, add one before trusting
   anything else it prints.
5. **Does it repeat?** At least 5 runs per side, interleaved (A B A B ...) so start-up costs,
   cache warming and machine drift land on both sides equally. Report the median and the range.
   If the two medians sit closer together than either side's own spread, call it no
   difference. For a near tie let a statistical test decide: Mann-Whitney U
   (`scipy.stats.mannwhitneyu`), `benchstat`, or criterion's change report. hyperfine and most
   harnesses time each side as one block, so interleave rounds yourself:

   ```bash
   # 7 rounds of before/after; one line per run: side<TAB>seconds
   for i in 1 2 3 4 5 6 7; do
     for side in before after; do
       hyperfine --runs 1 --export-json run.json "./$side/app --bench" >/dev/null
       printf '%s\t%s\n' "$side" "$(jq -r '.results[0].mean' run.json)"
     done
   done > runs.tsv
   # median and range per side
   sort -t "$(printf '\t')" -k1,1 -k2,2g runs.tsv | awk -F'\t' '
     function out() { m = (n % 2) ? x[(n + 1) / 2] : (x[n / 2] + x[n / 2 + 1]) / 2
                      printf "%s: median %.4f s, range %.4f-%.4f s, n=%d\n", s, m, x[1], x[n], n }
     $1 != s { if (s != "") out(); s = $1; n = 0 }
     { x[++n] = $2 }
     END { out() }'
   ```

6. **What share of end-to-end time is it?** A microbenchmark needs a companion: time the whole
   operation a user experiences, at production data volumes and concurrency, and express the
   micro gain as a percentage of that total. Shaving a function that accounts for 2% of request
   time can never save more than 2% of it.
7. **Did the work actually happen?** Count what the work produces (server-side request logs,
   rows in the table, bytes off disk, a checksum of the results) and compare it with what you
   sent. An unawaited promise, an undrained iterator, a result the compiler drops as unused, or
   a timeout that stops the clock early each give a quick time and no work. Benchmark
   libraries ship a sink against dead-code elimination (Rust's `std::hint::black_box`, JMH's
   `Blackhole`): use it.

## Verdicts

Open every report with exactly one:

| Verdict | Use when |
|---------|----------|
| faster / slower | the gap clears the spread (or a test), the bottleneck is named, both sides were tuned, errors and work were counted |
| no difference | the gap sits inside the spread |
| inconclusive | a difference appears but its bottleneck is unknown, one side wasn't tuned, or errors or work done weren't counted; say which check is missing |

**Inconclusive is never reported as a win.** Not rounded up to "faster" in a summary, not kept
by an `iterate` loop, not put in a PR title or changelog. It is a legitimate result: state what
would settle it.

State the figure with unit, run count, range and bottleneck, e.g. "p95 120 ms -> 96 ms (7
interleaved runs each; medians shown, after-runs spanned 93-99 ms); 0 errors; 50,000 requests
served on both sides; limited by TLS handshakes on a single core." Keep the raw runs
(`runs.tsv`) beside the report so a reviewer can check the claim without rerunning it.

## With iterate and evals

A timing metric is a noisy metric: measure its noise floor before hillclimbing on it
([iterate, "Noisy Metrics"](../../iterate/SKILL.md)). A harness that prints its error and work
counts next to the metric answers questions 4 and 7 on every keep/discard for free.

For an eval score the same doubts apply: check each trial completed its task, that the
difference survives repeated trials, and that the scenario is one users hit (`evals-ops`).
