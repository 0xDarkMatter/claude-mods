---
name: perf-ops
description: "Performance profiling and optimization orchestrator - diagnoses symptoms, dispatches profiling to language experts, manages before/after comparisons. Triggers on: performance, profiling, flamegraph, pprof, py-spy, clinic.js, memray, heaptrack, bundle size, webpack analyzer, load testing, k6, artillery, vegeta, locust, benchmark, hyperfine, criterion, slow query, EXPLAIN ANALYZE, N+1, caching, optimization, latency, throughput, p99, memory leak, CPU spike, bottleneck."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep Agent TaskCreate TaskUpdate"
metadata:
  author: claude-mods
  related-skills: debug-ops, monitoring-ops, testing-ops, code-stats, postgres-ops
---

# Performance Operations

Orchestrator for cross-language performance profiling and optimization. Classifies symptoms inline, dispatches profiling to language expert agents (background), and manages optimization with confirmation.

## Architecture

```
User describes performance issue or requests profiling
    |
    +---> T1: Diagnose (inline, fast)
    |       +---> Classify symptom (decision tree)
    |       +---> Detect language/runtime from project
    |       +---> Check installed profiling tools
    |       +---> Determine production vs development
    |       +---> Gather system baseline (CPU/mem/disk)
    |       +---> Present: diagnosis + recommended profiling approach
    |
    +---> T2: Profile (dispatch to language expert, background)
    |       +---> Select expert agent from routing table
    |       +---> Build perf-focused dispatch prompt
    |       +---> Expert runs profiler, collects data, interprets results
    |       |       +---> Fallback: general-purpose with tool commands inlined
    |       +---> Returns: findings + bottleneck identification + suggestions
    |       |
    |       +---> [Optional parallel dispatch]:
    |             +---> CPU profiling agent  ---+
    |             +---> Memory profiling agent --+--> Consolidate findings
    |             +---> Baseline benchmark ------+
    |
    +---> T3: Optimize (dispatch to expert, foreground + confirm)
            +---> Expert proposes specific code changes
            +---> Preflight: what changes, expected impact, risks
            +---> User confirms
            +---> Apply changes
            +---> Re-benchmark for before/after delta
```

## Safety Tiers

### T1: Diagnose - Run Inline

No agent needed. Execute directly via Bash for instant results.

| Operation | Command / Method |
|-----------|-----------------|
| Detect Python profilers | `which py-spy && which memray && which scalene` |
| Detect Go profilers | `which go && go tool pprof -h 2>/dev/null` |
| Detect Rust profilers | `which cargo-flamegraph && which samply` |
| Detect Node profilers | `which clinic && which 0x` |
| Detect benchmarking tools | `which hyperfine && which k6 && which vegeta` |
| System CPU baseline | `top -bn1 -o %CPU \| head -20` (Linux) or `wmic cpu get loadpercentage` (Win) |
| System memory baseline | `free -h` (Linux) or `wmic OS get FreePhysicalMemory` (Win) |
| Disk I/O check | `iostat -x 1 3` (Linux) |
| Identify language | Check for `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, `requirements.txt` |
| Production vs dev | Ask user or detect from environment (NODE_ENV, FLASK_ENV, etc.) |
| Read existing profiles | Parse `.prof`, `.svg`, `.bin` files in project |

**Production safety rule:** In production environments, only recommend sampling profilers (py-spy, pprof HTTP endpoint, perf). Never suggest attaching debuggers, tracing profilers, or tools that require process restart.

### T2: Profile - Dispatch to Expert Agent

Gather context from T1 diagnosis, then dispatch to the appropriate language expert.

**Language Expert Routing:**

| Detected Language | Expert Agent | Key Profiling Tools |
|-------------------|-------------|---------------------|
| Python (.py, pyproject.toml, requirements.txt) | python-expert | py-spy, memray, scalene, tracemalloc |
| Go (go.mod, .go files) | go-expert | pprof (CPU/heap/goroutine/mutex), benchstat |
| Rust (Cargo.toml, .rs files) | rust-expert | cargo-flamegraph, samply, DHAT, criterion |
| TypeScript/JavaScript (backend, package.json + server) | javascript-expert | clinic flame/doctor/bubbleprof, 0x |
| TypeScript/JavaScript (frontend, bundle issues) | typescript-expert | webpack-bundle-analyzer, Lighthouse, source-map-explorer |
| SQL / PostgreSQL | postgres-expert | EXPLAIN ANALYZE, pg_stat_statements, pgbench |
| General / unknown / CLI benchmarking | general-purpose | hyperfine, perf, strace |

**Dispatch template (T2):**

```
You are handling a performance profiling task dispatched by the perf-ops orchestrator.

## Diagnosis (from T1)
- Symptom: {classified symptom from decision tree}
- Language/Runtime: {detected language}
- Environment: {production | development}
- Installed tools: {list from tool detection}
- System baseline: {CPU/memory/disk metrics}

## Profiling Task
{specific profiling request - e.g., "CPU profile the API server under load"}

## Target
- Process/file: {target application or endpoint}
- Expected workload: {how to generate representative load if needed}

## Domain Knowledge
Before starting, read the relevant profiling reference for this language:
- Read: skills/perf-ops/references/cpu-memory-profiling.md

For load testing tasks, also read:
- Read: skills/perf-ops/references/load-testing.md

For database profiling, also read:
- Read: skills/postgres-ops/SKILL.md (if PostgreSQL)

## Instructions
1. Run the appropriate profiler for this language and symptom
2. Collect sufficient samples (minimum 30 seconds for CPU, multiple snapshots for memory)
3. Interpret the results - identify the top 3-5 bottlenecks
4. For each bottleneck: explain what it is, why it's slow, and suggest a fix
5. Report findings in structured format with metrics
```

**Execution mode:**

| Scenario | Mode | Why |
|----------|------|-----|
| User waiting for results | `run_in_background=False` | They need findings before continuing |
| User continuing other work | `run_in_background=True` | Don't block the main session |
| Quick benchmark (hyperfine) | `run_in_background=False` | Fast enough to wait |
| Load test (k6, artillery) | `run_in_background=True` | Takes minutes |

### T3: Optimize - Preflight Required

Dispatch to language expert with explicit instruction to produce a preflight report before any code changes.

**Dispatch template (T3 preflight):**

```
You are handling a performance optimization dispatched by the perf-ops orchestrator.

## Profiling Results (from T2)
{bottleneck findings, metrics, flamegraph interpretation}

## Optimization Request
{specific optimization - e.g., "Fix the N+1 query in UserController.list"}

IMPORTANT: Do NOT apply changes yet. Produce a Preflight Report:
1. Exactly what code/config changes you will make
2. Expected performance improvement (with reasoning)
3. Risks (correctness, side effects, edge cases)
4. How to verify the improvement (specific benchmark or test)
5. How to revert if the optimization causes issues
```

**After user confirms:** Re-dispatch with execute authority plus the before/after protocol.

**Dispatch template (T3 execute + before/after):**

```
User confirmed the optimization. Proceed with execution.

## Approved Changes
{exact changes from preflight report}

## Before/After Protocol
1. Record the current benchmark baseline: {specific command from T2}
2. Apply the approved changes
3. Run the same benchmark again
4. Report comparison:
   - Metric: before value -> after value (% change)
   - Include statistical confidence if tool supports it
5. If regression detected: revert and report
```

## Parallel Profiling

When multiple independent symptoms are detected, or the user requests comprehensive profiling, dispatch parallel agents.

**Parallelizable combinations:**

| Agent 1 | Agent 2 | Why Independent |
|---------|---------|-----------------|
| CPU profiler | Memory profiler | Different tools, different data |
| CPU profiler | Baseline benchmark | Read vs measurement |
| Backend profiler | Frontend bundle analysis | Different runtimes |
| Service A profiler | Service B profiler | Different processes |

**NOT parallelizable:**

| Operation A | Operation B | Why Sequential |
|-------------|-------------|----------------|
| Profile | Interpret results | Dependency |
| Before benchmark | After benchmark | Requires code change between |
| Load test | CPU profile same process | Tool interference |

**Dispatch pattern for parallel profiling:**

```python
# Example: CPU + memory profiling in parallel
Agent(
    subagent_type="python-expert",
    model="sonnet",
    run_in_background=True,
    prompt="CPU profiling task: {cpu_prompt}"
)
Agent(
    subagent_type="python-expert",
    model="sonnet",
    run_in_background=True,
    prompt="Memory profiling task: {memory_prompt}"
)
# Both run simultaneously, consolidate findings when both complete
```

## Fallback: When Expert Agent Is Unavailable

If the target language expert is not registered as a subagent type, fall back to `general-purpose` with profiling commands inlined.

```python
Agent(
    subagent_type="general-purpose",
    model="sonnet",
    run_in_background=True,
    prompt="""You are acting as a performance profiling agent for {language}.

Use these specific tools and commands:
{tool commands from diagnosis-quickref.md for the detected language}

{original dispatch prompt}
"""
)
```

For simple benchmarks (hyperfine, single command timing), skip agent dispatch entirely and run inline via Bash.

## Decision Logic

When a performance-related request arrives:

```
1. Classify the request:
   - Symptom description? -> Start at T1 (diagnose)
   - "Profile my app"? -> T1 (detect language + tools) then T2 (profile)
   - "Benchmark X vs Y"? -> T2 directly (hyperfine or language benchmark)
   - "Optimize this"? -> T2 (profile first) then T3 (optimize)
   - "Why is X slow"? -> T1 (diagnose) then T2 (targeted profile)

2. T1 Diagnose (always runs first for new issues):
   - Detect language/runtime
   - Check installed profiling tools
   - Classify symptom using decision tree (see diagnosis-quickref.md)
   - Determine production vs development
   - Present findings + recommend next step

3. T2 Profile (when diagnosis points to a specific bottleneck):
   - Route to appropriate language expert
   - Decide foreground vs background
   - Consider parallel dispatch if multiple symptoms
   - Consolidate findings from all agents

4. T3 Optimize (only when user wants changes applied):
   - Always produce preflight report first
   - Wait for explicit user confirmation
   - Execute with before/after comparison
   - Report delta with statistical confidence
```

## Quick Reference

| Task | Tier | Execution |
|------|------|-----------|
| Detect tools | T1 | Inline |
| Check system metrics | T1 | Inline |
| Classify symptom | T1 | Inline |
| Identify language | T1 | Inline |
| Run CPU profiler | T2 | Agent (bg) |
| Run memory profiler | T2 | Agent (bg) |
| Run load test | T2 | Agent (bg) |
| Run benchmark | T2 | Agent (bg or inline for hyperfine) |
| Bundle analysis | T2 | Agent (bg) |
| EXPLAIN ANALYZE | T2 | Agent (fg) |
| Before/after comparison | T2 | Agent (fg) |
| Apply optimization | T3 | Agent + confirm |
| Add index | T3 | Agent + confirm |
| Refactor hot path | T3 | Agent + confirm |

## Reference Files

| File | Contents |
|------|----------|
| `references/diagnosis-quickref.md` | Decision tree, tool selection matrix, quick references for all profiling domains, common gotchas |
| `references/cpu-memory-profiling.md` | Deep flamegraph interpretation, language-specific CPU/memory profiling guides |
| `references/load-testing.md` | k6, Artillery, vegeta, wrk, Locust methodology and CI integration |
| `references/optimization-patterns.md` | Caching, database, frontend, API, concurrency, memory optimization strategies |
| `references/ci-integration.md` | Performance budgets, regression detection, CI pipeline patterns, benchmark baselines |

Load reference files when deeper tool-specific guidance is needed beyond what the dispatch prompt provides.

## See Also

| Skill | When to Combine |
|-------|----------------|
| `debug-ops` | Root cause analysis for performance regressions |
| `monitoring-ops` | Production metrics, alerting on latency/throughput |
| `testing-ops` | Performance regression tests in CI, benchmark suites |
| `code-stats` | Identify complex code that may be performance-sensitive |
| `postgres-ops` | PostgreSQL-specific query optimization, indexing, EXPLAIN |
| `container-orchestration` | Resource limits, pod scaling, container performance |
