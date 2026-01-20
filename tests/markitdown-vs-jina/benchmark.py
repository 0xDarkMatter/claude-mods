#!/usr/bin/env python3
"""
Benchmark: markitdown vs Jina Reader vs Firecrawl
Compare speed, accuracy, formatting, and parallel execution
"""

import subprocess
import time
import os
import sys
import concurrent.futures
from pathlib import Path
from urllib.parse import quote

# Force UTF-8 encoding on Windows
if sys.platform == "win32":
    import codecs
    sys.stdout = codecs.getwriter("utf-8")(sys.stdout.buffer, errors="replace")
    sys.stderr = codecs.getwriter("utf-8")(sys.stderr.buffer, errors="replace")

# Test corpus - 10 URLs of varying complexity
URLS = [
    # News articles - use stable landing pages
    ("guardian-tech", "https://www.theguardian.com/technology"),
    ("bbc-news", "https://www.bbc.com/news"),

    # Documentation
    ("python-docs", "https://docs.python.org/3/library/asyncio.html"),
    ("mdn-fetch", "https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API"),
    ("rust-book", "https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html"),

    # Feature-rich / Complex
    ("github-repo", "https://github.com/microsoft/markitdown"),
    ("hackernews", "https://news.ycombinator.com/"),
    ("wikipedia", "https://en.wikipedia.org/wiki/Markdown"),

    # Simple / Minimal
    ("example-com", "https://example.com"),
    ("httpbin", "https://httpbin.org/html"),
]

OUTPUT_DIR = Path(__file__).parent / "output"

def fetch_with_markitdown(url: str, name: str) -> dict:
    """Fetch URL with markitdown, return timing and output"""
    output_file = OUTPUT_DIR / f"{name}_markitdown.md"
    start = time.perf_counter()
    try:
        result = subprocess.run(
            ["markitdown", url],
            capture_output=True,
            text=True,
            timeout=60,
            encoding="utf-8",
            errors="replace"
        )
        elapsed = time.perf_counter() - start
        output = result.stdout or ""
        error = result.stderr or ""
        success = result.returncode == 0 and len(output) > 50
    except subprocess.TimeoutExpired:
        elapsed = 60.0
        output = ""
        error = "TIMEOUT"
        success = False
    except Exception as e:
        elapsed = time.perf_counter() - start
        output = ""
        error = str(e)
        success = False

    if success and output:
        output_file.write_text(output, encoding="utf-8")

    return {
        "tool": "markitdown",
        "name": name,
        "url": url,
        "time": elapsed,
        "success": success,
        "output_len": len(output),
        "error": error if not success else None,
        "output_file": str(output_file) if success else None
    }

def fetch_with_jina(url: str, name: str) -> dict:
    """Fetch URL with Jina Reader, return timing and output"""
    output_file = OUTPUT_DIR / f"{name}_jina.md"
    jina_url = f"https://r.jina.ai/{url}"
    start = time.perf_counter()
    try:
        result = subprocess.run(
            ["curl", "-s", "-L", "--max-time", "60", jina_url],
            capture_output=True,
            text=True,
            timeout=65,
            encoding="utf-8",
            errors="replace"
        )
        elapsed = time.perf_counter() - start
        output = result.stdout or ""
        error = result.stderr
        success = result.returncode == 0 and len(output) > 100
    except subprocess.TimeoutExpired:
        elapsed = 60.0
        output = ""
        error = "TIMEOUT"
        success = False
    except Exception as e:
        elapsed = time.perf_counter() - start
        output = ""
        error = str(e)
        success = False

    if success and output:
        output_file.write_text(output, encoding="utf-8")

    return {
        "tool": "jina",
        "name": name,
        "url": url,
        "time": elapsed,
        "success": success,
        "output_len": len(output),
        "error": error if not success else None,
        "output_file": str(output_file) if success else None
    }

def fetch_with_firecrawl(url: str, name: str) -> dict:
    """Fetch URL with Firecrawl, return timing and output"""
    output_file = OUTPUT_DIR / f"{name}_firecrawl.md"
    start = time.perf_counter()
    try:
        # On Windows, firecrawl is a .cmd script - need shell=True
        result = subprocess.run(
            f"firecrawl {url}",
            capture_output=True,
            text=True,
            timeout=90,  # Firecrawl can be slower due to JS rendering
            encoding="utf-8",
            errors="replace",
            shell=True
        )
        elapsed = time.perf_counter() - start
        output = result.stdout or ""
        error = result.stderr
        success = result.returncode == 0 and len(output) > 100
    except subprocess.TimeoutExpired:
        elapsed = 90.0
        output = ""
        error = "TIMEOUT"
        success = False
    except Exception as e:
        elapsed = time.perf_counter() - start
        output = ""
        error = str(e)
        success = False

    if success and output:
        output_file.write_text(output, encoding="utf-8")

    return {
        "tool": "firecrawl",
        "name": name,
        "url": url,
        "time": elapsed,
        "success": success,
        "output_len": len(output),
        "error": error if not success else None,
        "output_file": str(output_file) if success else None
    }

def run_sequential():
    """Run all tests sequentially"""
    print("\n" + "="*60)
    print("SEQUENTIAL EXECUTION")
    print("="*60)

    results = {"markitdown": [], "jina": [], "firecrawl": []}

    for name, url in URLS:
        print(f"\nTesting: {name}")
        print(f"  URL: {url}")

        # markitdown
        r1 = fetch_with_markitdown(url, name)
        status1 = "OK" if r1["success"] else "FAIL"
        print(f"  markitdown: {r1['time']:.2f}s, {r1['output_len']:,} chars - {status1}")
        results["markitdown"].append(r1)

        # jina
        r2 = fetch_with_jina(url, name)
        status2 = "OK" if r2["success"] else "FAIL"
        print(f"  jina:       {r2['time']:.2f}s, {r2['output_len']:,} chars - {status2}")
        results["jina"].append(r2)

        # firecrawl
        r3 = fetch_with_firecrawl(url, name)
        status3 = "OK" if r3["success"] else "FAIL"
        print(f"  firecrawl:  {r3['time']:.2f}s, {r3['output_len']:,} chars - {status3}")
        results["firecrawl"].append(r3)

    return results

def run_parallel(tool: str, max_workers: int = 5):
    """Run all tests in parallel for a single tool"""
    print(f"\n{'='*60}")
    print(f"PARALLEL EXECUTION: {tool} (max_workers={max_workers})")
    print("="*60)

    fetch_fns = {
        "markitdown": fetch_with_markitdown,
        "jina": fetch_with_jina,
        "firecrawl": fetch_with_firecrawl
    }
    fetch_fn = fetch_fns[tool]

    start = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {
            executor.submit(fetch_fn, url, name): name
            for name, url in URLS
        }
        results = []
        for future in concurrent.futures.as_completed(futures):
            name = futures[future]
            result = future.result()
            status = "OK" if result["success"] else f"FAIL"
            print(f"  {name}: {result['time']:.2f}s - {status}")
            results.append(result)

    total_time = time.perf_counter() - start
    print(f"\nTotal parallel time: {total_time:.2f}s")

    return results, total_time

def print_summary(seq_results: dict, par_results: dict):
    """Print comparison summary"""
    print("\n" + "="*60)
    print("SUMMARY")
    print("="*60)

    # Sequential times
    md_times = [r["time"] for r in seq_results["markitdown"] if r["success"]]
    jina_times = [r["time"] for r in seq_results["jina"] if r["success"]]
    fc_times = [r["time"] for r in seq_results["firecrawl"] if r["success"]]

    md_success = sum(1 for r in seq_results["markitdown"] if r["success"])
    jina_success = sum(1 for r in seq_results["jina"] if r["success"])
    fc_success = sum(1 for r in seq_results["firecrawl"] if r["success"])

    md_chars = sum(r["output_len"] for r in seq_results["markitdown"] if r["success"])
    jina_chars = sum(r["output_len"] for r in seq_results["jina"] if r["success"])
    fc_chars = sum(r["output_len"] for r in seq_results["firecrawl"] if r["success"])

    def safe_avg(times):
        return sum(times)/len(times) if times else 0

    print("\n## Speed (Sequential)")
    print(f"| Metric | markitdown | Jina | Firecrawl |")
    print(f"|--------|------------|------|-----------|")
    print(f"| Avg time | {safe_avg(md_times):.2f}s | {safe_avg(jina_times):.2f}s | {safe_avg(fc_times):.2f}s |")
    print(f"| Total time | {sum(md_times):.2f}s | {sum(jina_times):.2f}s | {sum(fc_times):.2f}s |")
    print(f"| Success rate | {md_success}/{len(URLS)} | {jina_success}/{len(URLS)} | {fc_success}/{len(URLS)} |")

    print("\n## Speed (Parallel, 5 workers)")
    print(f"| Metric | markitdown | Jina | Firecrawl |")
    print(f"|--------|------------|------|-----------|")
    print(f"| Total time | {par_results['markitdown'][1]:.2f}s | {par_results['jina'][1]:.2f}s | {par_results['firecrawl'][1]:.2f}s |")

    print("\n## Output Size")
    print(f"| Metric | markitdown | Jina | Firecrawl |")
    print(f"|--------|------------|------|-----------|")
    print(f"| Total chars | {md_chars:,} | {jina_chars:,} | {fc_chars:,} |")
    print(f"| Avg chars | {md_chars//max(md_success,1):,} | {jina_chars//max(jina_success,1):,} | {fc_chars//max(fc_success,1):,} |")

    print("\n## Per-URL Comparison")
    print(f"| URL | markitdown | Jina | Firecrawl | Winner |")
    print(f"|-----|------------|------|-----------|--------|")
    for i, (name, url) in enumerate(URLS):
        md = seq_results["markitdown"][i]
        jn = seq_results["jina"][i]
        fc = seq_results["firecrawl"][i]

        md_str = f"{md['time']:.1f}s" if md["success"] else "FAIL"
        jn_str = f"{jn['time']:.1f}s" if jn["success"] else "FAIL"
        fc_str = f"{fc['time']:.1f}s" if fc["success"] else "FAIL"

        # Determine winner by speed among successful tools
        successful = []
        if md["success"]: successful.append(("markitdown", md["time"]))
        if jn["success"]: successful.append(("Jina", jn["time"]))
        if fc["success"]: successful.append(("Firecrawl", fc["time"]))

        if successful:
            winner = min(successful, key=lambda x: x[1])[0]
        else:
            winner = "None"

        print(f"| {name} | {md_str} | {jn_str} | {fc_str} | {winner} |")

    print(f"\nOutput files saved to: {OUTPUT_DIR}")

def main():
    # Create output directory
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("Benchmark: markitdown vs Jina Reader vs Firecrawl")
    print(f"Testing {len(URLS)} URLs")

    # Run sequential tests
    seq_results = run_sequential()

    # Run parallel tests
    par_results = {
        "markitdown": run_parallel("markitdown", max_workers=5),
        "jina": run_parallel("jina", max_workers=5),
        "firecrawl": run_parallel("firecrawl", max_workers=5),
    }

    # Print summary
    print_summary(seq_results, par_results)

if __name__ == "__main__":
    main()
