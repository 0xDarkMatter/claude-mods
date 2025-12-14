#!/usr/bin/env python3
"""
Perplexity CLI - Simple wrapper for Perplexity API.

Zero external dependencies - uses only Python stdlib.
Provides web-grounded AI answers with automatic citations.

Usage:
    perplexity "What is Claude Code?"
    perplexity -m sonar-reasoning "Complex analysis question"
    cat code.py | perplexity "Review this code"
    perplexity --json "query" > output.json

Environment:
    PERPLEXITY_API_KEY - API key (or set in ~/.claude/conclave.yaml)
    PERPLEXITY_VERBOSE - Show token usage when set
"""
import argparse
import json
import os
import sys
import urllib.request
import urllib.error

API_URL = "https://api.perplexity.ai/chat/completions"
MODELS = {
    "sonar": "Fast, cost-effective for quick facts",
    "sonar-pro": "Complex queries, more citations (default)",
    "sonar-reasoning": "Multi-step problem solving",
    "sonar-reasoning-pro": "Deep reasoning (DeepSeek-R1)",
    "sonar-deep-research": "Comprehensive research with agentic search",
}
DEFAULT_MODEL = "sonar-pro"


def get_api_key():
    """Get API key from env or config file."""
    import re

    # Try environment variable first
    key = os.getenv("PERPLEXITY_API_KEY")
    if key:
        return key

    # Try ~/.claude/conclave.yaml
    config_path = os.path.expanduser("~/.claude/conclave.yaml")
    if os.path.exists(config_path):
        try:
            with open(config_path, encoding="utf-8") as f:
                content = f.read()
            # Look for perplexity key in api_keys section
            # Parse the api_keys block and find perplexity
            in_api_keys = False
            for line in content.split('\n'):
                stripped = line.strip()
                # Detect api_keys section
                if stripped.startswith('api_keys:'):
                    in_api_keys = True
                    continue
                # Exit section on non-indented line (new section)
                if in_api_keys and stripped and not line.startswith(' ') and not line.startswith('\t'):
                    if not stripped.startswith('#'):
                        in_api_keys = False
                # Look for perplexity key within api_keys section
                if in_api_keys and 'perplexity:' in stripped.lower():
                    match = re.search(r'perplexity:\s*["\']?([^"\'\n#]+)', stripped, re.IGNORECASE)
                    if match:
                        return match.group(1).strip()
        except Exception:
            pass

    return None


def query_perplexity(prompt, model=DEFAULT_MODEL, system_prompt=None, recency=None, domains=None):
    """Send query to Perplexity API and return response."""
    api_key = get_api_key()
    if not api_key:
        sys.exit(
            "Error: PERPLEXITY_API_KEY not set.\n"
            "Set via: export PERPLEXITY_API_KEY='your-key'\n"
            "Or add to ~/.claude/conclave.yaml under api_keys:"
        )

    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": model,
        "messages": messages,
    }

    # Optional search filters
    if recency:
        payload["search_recency_filter"] = recency
    if domains:
        payload["search_domain_filter"] = domains

    data = json.dumps(payload).encode("utf-8")
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    req = urllib.request.Request(API_URL, data=data, headers=headers)

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            result = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code == 401:
            sys.exit("Error: Invalid API key")
        elif e.code == 429:
            sys.exit("Error: Rate limited. Wait and retry.")
        else:
            body = ""
            try:
                body = e.read().decode("utf-8")
            except Exception:
                pass
            sys.exit(f"Error: HTTP {e.code} - {e.reason}\n{body}")
    except urllib.error.URLError as e:
        sys.exit(f"Error: Network error - {e.reason}")
    except Exception as e:
        sys.exit(f"Error: {e}")

    return result


def safe_print(text):
    """Print text safely, handling encoding issues on Windows."""
    try:
        print(text)
    except UnicodeEncodeError:
        # Fallback: encode with replacement for unsupported chars
        print(text.encode(sys.stdout.encoding, errors='replace').decode(sys.stdout.encoding))


def format_output(result, show_citations=True, json_output=False):
    """Format and print the response."""
    if json_output:
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return

    # Extract content
    try:
        content = result["choices"][0]["message"]["content"]
    except (KeyError, IndexError):
        print("Error: Unexpected response format")
        print(json.dumps(result, indent=2))
        return

    citations = result.get("citations", [])
    usage = result.get("usage", {})

    safe_print(content)

    # Show citations if available and requested
    if show_citations and citations:
        safe_print("\n---")
        safe_print("Sources:")
        for i, cite in enumerate(citations, 1):
            safe_print(f"  [{i}] {cite}")

    # Show usage if verbose
    if os.getenv("PERPLEXITY_VERBOSE"):
        total = usage.get("total_tokens", "N/A")
        print(f"\n[Tokens: {total}]")


def main():
    parser = argparse.ArgumentParser(
        description="Perplexity CLI - Web-grounded AI answers with citations",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Models:
  sonar                Fast, cost-effective for quick facts
  sonar-pro            Complex queries, more citations (default)
  sonar-reasoning      Multi-step problem solving
  sonar-reasoning-pro  Deep reasoning (DeepSeek-R1 based)
  sonar-deep-research  Comprehensive agentic research

Examples:
  perplexity "What's new in TypeScript 5.7?"
  perplexity -m sonar-reasoning "Analyze this security pattern"
  cat code.py | perplexity "Review this code for issues"
  perplexity --json "query" > output.json

  # Filter by recency (day, week, month, year)
  perplexity --recency day "Latest AI news"

  # Restrict to specific domains
  perplexity --domains "github.com,docs.python.org" "Python asyncio best practices"

Environment:
  PERPLEXITY_API_KEY  API key (required, or set in ~/.claude/conclave.yaml)
  PERPLEXITY_VERBOSE  Show token usage when set
""",
    )
    parser.add_argument("prompt", nargs="?", help="Query prompt")
    parser.add_argument(
        "-m",
        "--model",
        default=DEFAULT_MODEL,
        choices=list(MODELS.keys()),
        help=f"Model to use (default: {DEFAULT_MODEL})",
    )
    parser.add_argument("-s", "--system", default=None, help="System prompt")
    parser.add_argument(
        "--no-citations", action="store_true", help="Suppress citation output"
    )
    parser.add_argument(
        "--json", action="store_true", help="Output raw JSON response"
    )
    parser.add_argument(
        "--list-models", action="store_true", help="List available models"
    )
    parser.add_argument(
        "--recency",
        choices=["day", "week", "month", "year"],
        help="Filter search results by recency",
    )
    parser.add_argument(
        "--domains",
        type=str,
        help="Comma-separated domains to include (e.g., 'github.com,stackoverflow.com')",
    )

    args = parser.parse_args()

    # List models
    if args.list_models:
        print("Available models:")
        for name, desc in MODELS.items():
            marker = " (default)" if name == DEFAULT_MODEL else ""
            print(f"  {name}{marker}: {desc}")
        return 0

    # Get prompt from argument and/or stdin
    prompt = args.prompt
    stdin_content = ""

    # Read stdin once if available (piped input)
    if not sys.stdin.isatty():
        try:
            stdin_content = sys.stdin.read().strip()
        except Exception:
            stdin_content = ""

    # Combine stdin and prompt argument
    if stdin_content and prompt:
        # Both stdin and argument: stdin as context, prompt as instruction
        prompt = f"{stdin_content}\n\n{prompt}"
    elif stdin_content:
        # Only stdin content
        prompt = stdin_content
    elif not prompt:
        # No input at all
        parser.print_help()
        return 1

    # Parse domains if provided
    domains = None
    if args.domains:
        domains = [d.strip() for d in args.domains.split(",")]

    # Query and output
    result = query_perplexity(
        prompt,
        model=args.model,
        system_prompt=args.system,
        recency=args.recency,
        domains=domains,
    )
    format_output(result, show_citations=not args.no_citations, json_output=args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
