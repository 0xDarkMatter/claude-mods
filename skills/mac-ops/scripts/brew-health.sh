#!/usr/bin/env bash
# mac-ops :: brew-health.sh
# Homebrew state audit. Most Mac developers have brew installed; outdated
# packages, broken casks, and brew doctor warnings are a frequent silent
# cause of "this dev tool stopped working".

set -u

# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --json, --redact, --quiet, --verbose

Reports:
  1. brew + paths sanity (Intel /usr/local vs Apple Silicon /opt/homebrew)
  2. brew doctor summary
  3. Outdated formulae + casks
  4. Cleanup opportunities (caches, deprecated)
  5. Pinned formulae (held back on purpose vs by accident)
  6. brew services state
  7. Tap inventory

If brew isn't installed, the script exits cleanly with [INFO] markers.
EOF
            exit 0 ;;
        *) shift ;;
    esac
done
# Without this restore every standard flag was silently ignored (--redact
# output meant for sharing went out unredacted). ${a[@]+...} is the bash
# 3.2-safe expansion of a possibly empty array under set -u.
set -- ${SAVED_ARGS[@]+"${SAVED_ARGS[@]}"}

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

# ----------------------------------------------------------------------------
section "1. BREW INSTALLATION"
# ----------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    log_info "Homebrew" "not installed on this Mac"
    emit_summary
    exit 0
fi

brew_path=$(command -v brew)
brew_prefix=$(brew --prefix 2>/dev/null)
brew_version=$(brew --version 2>/dev/null | head -1)
log_pass "Homebrew" "$brew_version"
note "  brew: $brew_path"
note "  prefix: $brew_prefix"

# Architecture sanity
if is_apple_silicon; then
    if [[ "$brew_prefix" == "/opt/homebrew"* ]]; then
        log_pass "Architecture match" "Apple Silicon + native /opt/homebrew"
    elif [[ "$brew_prefix" == "/usr/local"* ]]; then
        log_warn "Architecture mismatch" "Apple Silicon Mac running x86_64 brew via Rosetta"
    fi
else
    if [[ "$brew_prefix" == "/usr/local"* ]]; then
        log_pass "Architecture match" "Intel + /usr/local"
    fi
fi

# ----------------------------------------------------------------------------
section "2. BREW DOCTOR"
# ----------------------------------------------------------------------------
doctor_out=$(brew doctor 2>&1)
if echo "$doctor_out" | grep -q "Your system is ready to brew"; then
    log_pass "brew doctor" "Your system is ready to brew"
else
    warnings=$(echo "$doctor_out" | grep -c "^Warning:" || echo 0)
    log_warn "brew doctor" "$warnings warning(s) — see below"
    note "  Top doctor messages (first 15 lines):"
    echo "$doctor_out" | head -15 | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
section "3. OUTDATED PACKAGES"
# ----------------------------------------------------------------------------
formulae_out=$(brew outdated --formula 2>/dev/null)
formulae_count=$(echo "$formulae_out" | grep -c . 2>/dev/null || echo 0)
casks_out=$(brew outdated --cask 2>/dev/null)
casks_count=$(echo "$casks_out" | grep -c . 2>/dev/null || echo 0)

if [[ "$formulae_count" -gt 0 ]]; then
    log_info "Outdated formulae" "$formulae_count"
    echo "$formulae_out" | head -10 | sed 's/^/    /'
else
    log_pass "Outdated formulae" "0"
fi

if [[ "$casks_count" -gt 0 ]]; then
    log_info "Outdated casks" "$casks_count"
    echo "$casks_out" | head -10 | sed 's/^/    /'
else
    log_pass "Outdated casks" "0"
fi

# ----------------------------------------------------------------------------
section "4. CLEANUP OPPORTUNITIES"
# ----------------------------------------------------------------------------
# brew cleanup --dry-run reports what would be removed
cleanup_dry=$(brew cleanup --dry-run 2>/dev/null | tail -5)
if [[ -n "$cleanup_dry" ]]; then
    note "  brew cleanup --dry-run (last 5 lines):"
    echo "$cleanup_dry" | sed 's/^/    /'
fi

# Cache size
cache_dir=$(brew --cache 2>/dev/null)
if [[ -d "$cache_dir" ]]; then
    cache_size=$(du -sh "$cache_dir" 2>/dev/null | awk '{print $1}')
    log_info "Brew cache size" "${cache_size:-?}"
fi

# Deprecated/abandoned packages
deprecated=$(brew list --formula 2>/dev/null | while read -r f; do
    if brew info --json=v1 "$f" 2>/dev/null | grep -q '"deprecated":true\|"disabled":true'; then
        echo "$f"
    fi
done | head -10)
if [[ -n "$deprecated" ]]; then
    n=$(echo "$deprecated" | wc -l | tr -d ' ')
    log_warn "Deprecated/disabled formulae installed" "$n"
    echo "$deprecated" | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
section "5. PINNED FORMULAE"
# ----------------------------------------------------------------------------
pinned=$(brew list --pinned 2>/dev/null)
if [[ -n "$pinned" ]]; then
    n=$(echo "$pinned" | wc -l | tr -d ' ')
    log_info "Pinned formulae" "$n"
    echo "$pinned" | sed 's/^/    /'
    note ""
    note "  Pinned packages don't get upgraded by 'brew upgrade'. Unpin:"
    note "    brew unpin <name>"
else
    log_pass "Pinned formulae" "0"
fi

# ----------------------------------------------------------------------------
section "6. BREW SERVICES"
# ----------------------------------------------------------------------------
if command -v brew >/dev/null 2>&1 && brew help services >/dev/null 2>&1; then
    services_out=$(brew services list 2>/dev/null | tail -n +2)
    if [[ -n "$services_out" ]]; then
        running=$(echo "$services_out" | awk '$2=="started"' | wc -l | tr -d ' ')
        total=$(echo "$services_out" | wc -l | tr -d ' ')
        log_info "Brew services" "$running running of $total"
        echo "$services_out" | sed 's/^/    /' | head -15
    else
        log_pass "Brew services" "none configured"
    fi
fi

# ----------------------------------------------------------------------------
section "7. TAPS"
# ----------------------------------------------------------------------------
taps=$(brew tap 2>/dev/null)
tap_count=$(echo "$taps" | grep -c . 2>/dev/null || echo 0)
log_info "Brew taps" "$tap_count"
echo "$taps" | head -10 | sed 's/^/    /'

# Third-party taps (not homebrew/*)
third_party_taps=$(echo "$taps" | grep -v "^homebrew/" || true)
if [[ -n "$third_party_taps" ]]; then
    n=$(echo "$third_party_taps" | wc -l | tr -d ' ')
    note ""
    note "  Third-party taps ($n) — these are external trust:"
    echo "$third_party_taps" | sed 's/^/    /'
fi

# ----------------------------------------------------------------------------
emit_summary

if [[ "$JSON_MODE" -eq 0 ]]; then
    echo
    note "  Quick cleanup playbook:"
    note "    brew update && brew upgrade        # update everything"
    note "    brew cleanup -s                    # remove old versions + caches"
    note "    brew autoremove                    # remove orphaned dependencies"
    note "    brew doctor                        # full doctor scan"
fi
