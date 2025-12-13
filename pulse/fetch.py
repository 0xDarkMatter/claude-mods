#!/usr/bin/env python3
"""
Pulse Fetch - Parallel URL fetching for Claude Code news digest.

Uses asyncio + ThreadPoolExecutor to fetch multiple URLs via Firecrawl simultaneously.
Outputs JSON with fetched content for LLM summarization.

Usage:
    python fetch.py                          # Fetch all sources
    python fetch.py --sources blogs          # Fetch only blogs
    python fetch.py --max-workers 20         # Increase parallelism
    python fetch.py --output pulse.json
    python fetch.py --discover-articles      # Extract recent articles from blog homepages
"""

import os
import sys
import json
import re
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlparse, urljoin
import argparse

# Try to import firecrawl
try:
    from firecrawl import FirecrawlApp
    FIRECRAWL_AVAILABLE = True
except ImportError:
    FIRECRAWL_AVAILABLE = False
    print("Warning: firecrawl not installed. Install with: pip install firecrawl-py")

# Sources configuration
SOURCES = {
    "official": [
        {"name": "Anthropic Engineering", "url": "https://www.anthropic.com/engineering", "type": "blog"},
        {"name": "Claude Blog", "url": "https://claude.ai/blog", "type": "blog"},
        {"name": "Claude Code Docs", "url": "https://code.claude.com", "type": "docs"},
    ],
    "blogs": [
        {"name": "Simon Willison", "url": "https://simonwillison.net", "type": "blog"},
        {"name": "Every", "url": "https://every.to", "type": "blog"},
        {"name": "SSHH Blog", "url": "https://blog.sshh.io", "type": "blog"},
        {"name": "Lee Han Chung", "url": "https://leehanchung.github.io", "type": "blog"},
        {"name": "Nick Nisi", "url": "https://nicknisi.com", "type": "blog"},
        {"name": "HumanLayer", "url": "https://www.humanlayer.dev/blog", "type": "blog"},
        {"name": "Chris Dzombak", "url": "https://www.dzombak.com/blog", "type": "blog"},
        {"name": "GitButler", "url": "https://blog.gitbutler.com", "type": "blog"},
        {"name": "Docker Blog", "url": "https://www.docker.com/blog", "type": "blog"},
        {"name": "Nx Blog", "url": "https://nx.dev/blog", "type": "blog"},
        {"name": "Yee Fei Ooi", "url": "https://medium.com/@ooi_yee_fei", "type": "blog"},
    ],
    "community": [
        {"name": "SkillsMP", "url": "https://skillsmp.com", "type": "marketplace"},
        {"name": "Awesome Claude AI", "url": "https://awesomeclaude.ai", "type": "directory"},
    ],
}

# Relevance keywords for filtering
RELEVANCE_KEYWORDS = [
    "claude", "claude code", "anthropic", "mcp", "model context protocol",
    "agent", "skill", "subagent", "cli", "terminal", "prompt engineering",
    "cursor", "windsurf", "copilot", "aider", "coding assistant", "hooks"
]

# Patterns to identify article links in markdown content
ARTICLE_LINK_PATTERNS = [
    # Standard markdown links with date-like paths
    r'\[([^\]]+)\]\((https?://[^\)]+/\d{4}/[^\)]+)\)',
    # Links with /blog/, /posts/, /p/ paths
    r'\[([^\]]+)\]\((https?://[^\)]+/(?:blog|posts?|p|articles?)/[^\)]+)\)',
    # Links with slugified titles (word-word-word pattern)
    r'\[([^\]]+)\]\((https?://[^\)]+/[\w]+-[\w]+-[\w]+[^\)]*)\)',
]

# Exclude patterns (navigation, categories, tags, etc.)
EXCLUDE_PATTERNS = [
    r'/tag/', r'/category/', r'/author/', r'/page/', r'/archive/',
    r'/about', r'/contact', r'/subscribe', r'/newsletter', r'/feed',
    r'/search', r'/login', r'/signup', r'/privacy', r'/terms',
    r'\.xml$', r'\.rss$', r'\.atom$', r'#', r'\?',
]


def fetch_url_firecrawl(app: 'FirecrawlApp', source: dict) -> dict:
    """Fetch a single URL using Firecrawl API."""
    url = source["url"]
    name = source["name"]

    try:
        result = app.scrape(url, formats=['markdown'])

        # Handle both dict and object responses
        if hasattr(result, 'markdown'):
            markdown = result.markdown or ''
            metadata = result.metadata.__dict__ if hasattr(result.metadata, '__dict__') else {}
        else:
            markdown = result.get('markdown', '')
            metadata = result.get('metadata', {})

        return {
            "name": name,
            "url": url,
            "type": source.get("type", "unknown"),
            "status": "success",
            "content": markdown[:50000],  # Limit content size
            "title": metadata.get('title', name),
            "description": metadata.get('description', ''),
            "fetched_at": datetime.utcnow().isoformat() + "Z",
        }
    except Exception as e:
        return {
            "name": name,
            "url": url,
            "type": source.get("type", "unknown"),
            "status": "error",
            "error": str(e),
            "fetched_at": datetime.utcnow().isoformat() + "Z",
        }


def fetch_all_parallel(sources: list, max_workers: int = 10) -> list:
    """Fetch all URLs in parallel using ThreadPoolExecutor."""
    if not FIRECRAWL_AVAILABLE:
        print("Error: firecrawl not available")
        return []

    api_key = os.getenv('FIRECRAWL_API_KEY')
    if not api_key:
        print("Error: FIRECRAWL_API_KEY environment variable not set")
        return []

    app = FirecrawlApp(api_key=api_key)
    results = []
    total = len(sources)
    completed = 0

    print(f"Fetching {total} URLs with {max_workers} workers...")

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        # Submit all tasks
        future_to_source = {
            executor.submit(fetch_url_firecrawl, app, source): source
            for source in sources
        }

        # Process results as they complete
        for future in as_completed(future_to_source):
            source = future_to_source[future]
            completed += 1

            try:
                result = future.result()
                results.append(result)
                status = "OK" if result["status"] == "success" else "FAIL"
                print(f"[{completed}/{total}] {status}: {source['name']}")
            except Exception as e:
                print(f"[{completed}/{total}] ERROR: {source['name']} - {e}")
                results.append({
                    "name": source["name"],
                    "url": source["url"],
                    "status": "error",
                    "error": str(e),
                })

    return results


def extract_article_links(content: str, base_url: str, max_articles: int = 5) -> list:
    """Extract article links from markdown content."""
    articles = []
    seen_urls = set()
    base_domain = urlparse(base_url).netloc

    for pattern in ARTICLE_LINK_PATTERNS:
        matches = re.findall(pattern, content)
        for title, url in matches:
            # Skip if already seen
            if url in seen_urls:
                continue

            # Skip excluded patterns
            if any(re.search(exc, url, re.IGNORECASE) for exc in EXCLUDE_PATTERNS):
                continue

            # Ensure same domain or relative URL
            parsed = urlparse(url)
            if parsed.netloc and parsed.netloc != base_domain:
                continue

            # Clean up title
            title = title.strip()
            if len(title) < 5 or len(title) > 200:
                continue

            # Skip generic link text
            if title.lower() in ['read more', 'continue reading', 'link', 'here', 'click here']:
                continue

            seen_urls.add(url)
            articles.append({
                "title": title,
                "url": url,
            })

    return articles[:max_articles]


def discover_articles(sources: list, max_workers: int = 10, max_articles_per_source: int = 5) -> list:
    """Fetch blog homepages and extract recent article links."""
    if not FIRECRAWL_AVAILABLE:
        print("Error: firecrawl not available")
        return []

    api_key = os.getenv('FIRECRAWL_API_KEY')
    if not api_key:
        print("Error: FIRECRAWL_API_KEY environment variable not set")
        return []

    # First, fetch all blog homepages
    print(f"Phase 1: Fetching {len(sources)} blog homepages...")
    homepage_results = fetch_all_parallel(sources, max_workers=max_workers)

    # Extract article links from each
    all_articles = []
    print(f"\nPhase 2: Extracting article links...")

    for result in homepage_results:
        if result["status"] != "success":
            continue

        content = result.get("content", "")
        base_url = result["url"]
        source_name = result["name"]

        articles = extract_article_links(content, base_url, max_articles=max_articles_per_source)
        print(f"  {source_name}: found {len(articles)} articles")

        for article in articles:
            all_articles.append({
                "name": article["title"],
                "url": article["url"],
                "type": "article",
                "source_name": source_name,
                "source_url": base_url,
            })

    if not all_articles:
        print("No articles found to fetch")
        return homepage_results

    # Phase 3: Fetch individual articles
    print(f"\nPhase 3: Fetching {len(all_articles)} individual articles...")
    article_results = fetch_all_parallel(all_articles, max_workers=max_workers)

    # Add source info to results
    for i, result in enumerate(article_results):
        if i < len(all_articles):
            result["source_name"] = all_articles[i].get("source_name", "")
            result["source_url"] = all_articles[i].get("source_url", "")

    return article_results


def filter_relevant_content(results: list) -> list:
    """Filter results to only those with Claude Code relevant content."""
    relevant = []

    for result in results:
        if result["status"] != "success":
            continue

        content = ((result.get("content") or "") + " " +
                   (result.get("title") or "") + " " +
                   (result.get("description") or "")).lower()

        # Check for relevance keywords
        for keyword in RELEVANCE_KEYWORDS:
            if keyword.lower() in content:
                result["relevant_keyword"] = keyword
                relevant.append(result)
                break

    return relevant


def main():
    parser = argparse.ArgumentParser(description="Pulse Fetch - Parallel URL fetching")
    parser.add_argument("--sources", choices=["all", "official", "blogs", "community"],
                        default="all", help="Source category to fetch")
    parser.add_argument("--max-workers", type=int, default=10,
                        help="Maximum parallel workers (default: 10)")
    parser.add_argument("--output", "-o", type=str, default=None,
                        help="Output JSON file (default: stdout)")
    parser.add_argument("--filter-relevant", action="store_true",
                        help="Only include results with relevant keywords")
    parser.add_argument("--discover-articles", action="store_true",
                        help="Extract and fetch individual articles from blog homepages")
    parser.add_argument("--max-articles-per-source", type=int, default=5,
                        help="Max articles to fetch per source (default: 5)")
    args = parser.parse_args()

    # Collect sources based on selection
    if args.sources == "all":
        sources = []
        for category in SOURCES.values():
            sources.extend(category)
    else:
        sources = SOURCES.get(args.sources, [])

    if not sources:
        print(f"No sources found for category: {args.sources}")
        return 1

    # Fetch URLs - either discover articles or just fetch homepages
    if args.discover_articles:
        # Filter to only blog-type sources for article discovery
        blog_sources = [s for s in sources if s.get("type") == "blog"]
        if not blog_sources:
            print("No blog sources found for article discovery")
            return 1
        results = discover_articles(
            blog_sources,
            max_workers=args.max_workers,
            max_articles_per_source=args.max_articles_per_source
        )
    else:
        results = fetch_all_parallel(sources, max_workers=args.max_workers)

    # Filter if requested
    if args.filter_relevant:
        results = filter_relevant_content(results)
        print(f"\nFiltered to {len(results)} relevant results")

    # Prepare output
    output = {
        "fetched_at": datetime.utcnow().isoformat() + "Z",
        "total_sources": len(sources),
        "successful": len([r for r in results if r.get("status") == "success"]),
        "failed": len([r for r in results if r.get("status") != "success"]),
        "results": results,
    }

    # Output
    json_output = json.dumps(output, indent=2)

    if args.output:
        Path(args.output).write_text(json_output, encoding="utf-8")
        print(f"\nResults saved to: {args.output}")
    else:
        print("\n" + "=" * 60)
        print("RESULTS")
        print("=" * 60)
        print(json_output)

    # Summary
    print(f"\n{'=' * 60}")
    print(f"SUMMARY: {output['successful']}/{output['total_sources']} successful")
    print(f"{'=' * 60}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
