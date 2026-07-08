#!/usr/bin/env bash
# Audit a GitHub repo's security posture — what's off, what's actually exposed.
#
# READ-ONLY. Only GET/HEAD `gh api` calls. The "enable" commands it prints are
# emitted as TEXT for you to review and run yourself — this script NEVER applies
# a change. It surfaces the blind spot: security features left off, and (where a
# scanner is on) the OPEN findings that prove real exposure. Severity is
# visibility-aware — a public repo gets free secret/push/code scanning, so a gap
# there is a real finding; a private repo without Advanced Security gets those as
# a NOTE ("needs GHAS"), not a nag.
#
# Usage:   check-security-posture.sh [--repo OWNER/REPO | --remote NAME | --org OWNER]
#                                    [--commands] [--json] [--strict] [--advisory]
#                                    [-h|--help]
# Input:   argv only. Default repo = derived from the 'origin' remote of the cwd.
# Output:  stdout = data (human checklist, --commands enable list, or --json envelope).
#          --json schema: claude-mods.github-ops.security-posture/v1
# Stderr:  headers, the review banner, skip notices, errors.
# Exit:    0  posture clean (all applicable features on, no open alerts)
#          2  usage (bad/unknown flag, malformed OWNER/REPO)
#          5  gh not installed (standalone; --advisory downgrades to a skip)
#          7  unavailable — non-github remote, gh unauthed/offline, timeout
#             (ADVISORY signal; never a real failure)
#          10 gaps and/or open alerts found (the thing to look at)
#
# Severity model (visibility-aware; documented so the mapping is auditable):
#   critical : open CRITICAL alerts present on an enabled scanner
#   high     : open HIGH alerts; OR (public/active) push-protection off;
#              OR (public/active) Dependabot alerts off
#   medium   : (public) secret-scanning or code-scanning off; Dependabot
#              security-updates off; no branch protection on the default branch
#   low      : SECURITY.md absent; private vulnerability reporting off
#   note     : feature needs paid GitHub Advanced Security on a private repo —
#              reported, but NOT counted as a gap (n/a unless GHAS is on)
# By default low+medium gaps DO count toward exit 10 (they are real, free gaps).
# --strict additionally makes any non-clean state exit 10 even in --advisory.
# Free-on-any-repo features (Dependabot alerts, Dependabot security updates,
# private vuln reporting, SECURITY.md) are always findings when off.
#
# Examples:
#   check-security-posture.sh --repo 0xDarkMatter/flarecrawl
#   check-security-posture.sh --remote origin
#   check-security-posture.sh --org 0xDarkMatter            # fleet sweep
#   check-security-posture.sh --repo OWNER/REPO --commands  # copy-paste enable cmds
#   check-security-posture.sh --repo OWNER/REPO --json | jq '.data[] | select(.state=="off")'
set -uo pipefail

EX_OK=0; EX_USAGE=2; EX_MISSING_DEP=5; EX_UNAVAILABLE=7; EX_FINDINGS=10
GH_TIMEOUT="${GH_TIMEOUT:-20}"   # seconds; bounds every network call

# Terminal design system (skills/_lib/term.sh). Framing prints to stderr, so detect
# color on fd 2. Degrade to plain output if the shared lib isn't reachable.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2
else
  term_panel_open()  { printf '== %s %s ==\n' "${2:-}" "${3:-}"; }
  term_panel_close() { [ -n "${1:-}" ] && printf '%s\n' "$1"; }
  term_panel_vert()  { :; }
  term_panel_line()  { printf '  %s\n' "$*"; }
  term_section()     { printf '%s (%s)\n' "${2:-}" "${3:-}"; }
  term_color()       { shift; printf '%s' "$*"; }
  term_mark()        { case "${1:-}" in ok) printf '+';; bad|gap) printf 'x';; warn) printf '!';; skip|na) printf '-';; unknown) printf '?';; *) printf '.';; esac; }
  term_health()      { shift; printf '%s' "$*"; }
fi

REPO=""; REMOTE="origin"; ORG=""; COMMANDS=0; JSON=0; STRICT=0; ADVISORY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:?--repo needs OWNER/REPO}"; shift 2 ;;
    --remote)   REMOTE="${2:?--remote needs a name}"; shift 2 ;;
    --org)      ORG="${2:?--org needs an OWNER}"; shift 2 ;;
    --commands) COMMANDS=1; shift ;;
    --json)     JSON=1; shift ;;
    --strict)   STRICT=1; shift ;;
    --advisory) ADVISORY=1; shift ;;
    -h|--help)  sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit "$EX_OK" ;;
    *) echo "check-security-posture: unknown argument: $1" >&2; exit "$EX_USAGE" ;;
  esac
done

# In advisory mode, any inability to check is a silent skip.
skip() { # message
  [ "$ADVISORY" -eq 1 ] || echo "check-security-posture: $1" >&2
  exit "$EX_UNAVAILABLE"
}

command -v gh >/dev/null 2>&1 || {
  [ "$ADVISORY" -eq 1 ] && exit "$EX_UNAVAILABLE"
  echo "check-security-posture: gh not installed (https://cli.github.com)" >&2
  exit "$EX_MISSING_DEP"
}
command -v jq >/dev/null 2>&1 || skip "jq not installed"

runner() { if command -v timeout >/dev/null 2>&1; then timeout "$GH_TIMEOUT" "$@"; else "$@"; fi; }

# Validate OWNER/REPO shape (agent safety — never interpolate a fabricated path).
valid_repo() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; }
valid_owner() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'; }

# --------------------------------------------------------------------------
# Per-repo audit. Emits one JSON object {repo, visibility, ghas, features:[...]}
# to stdout via `printf`. Returns 0 clean / 10 findings / 7 unavailable.
# Never crashes on a read error: unknown reads become state "unknown".
# --------------------------------------------------------------------------
audit_repo() { # OWNER/REPO  -> echoes a JSON object, returns 0|10|7
  local R="$1" core owner vis priv ghas ss ssp default_branch
  owner="${R%%/*}"

  core="$(runner gh api "repos/$R" 2>/dev/null)" || return 7
  [ -n "$core" ] || return 7

  vis="$(printf '%s' "$core" | jq -r '.visibility // (if .private then "private" else "public" end)')"
  priv="$(printf '%s' "$core" | jq -r '.private')"
  ghas="$(printf '%s' "$core" | jq -r '.security_and_analysis.advanced_security.status // "null"')"
  ss="$(printf '%s'  "$core" | jq -r '.security_and_analysis.secret_scanning.status // "null"')"
  ssp="$(printf '%s' "$core" | jq -r '.security_and_analysis.secret_scanning_push_protection.status // "null"')"
  default_branch="$(printf '%s' "$core" | jq -r '.default_branch // "main"')"

  local is_public=0; [ "$vis" = "public" ] && is_public=1
  local has_ghas=0; [ "$ghas" = "enabled" ] && has_ghas=1
  # Secret/push/code scanning are "applicable" (a gap if off) when free: public repo,
  # OR private repo with GHAS enabled. Otherwise they are a NOTE ("needs GHAS").
  local scan_applicable=0
  if [ "$is_public" -eq 1 ] || [ "$has_ghas" -eq 1 ]; then scan_applicable=1; fi

  # Each feature row appended to this jq array as a compact object.
  local features="[]"
  add() { # feature state applicable severity enable_command [open_alerts] [max_severity]
    features="$(jq -c \
      --arg f "$1" --arg st "$2" --argjson ap "$3" --arg sev "$4" --arg cmd "$5" \
      --arg oa "${6-}" --arg mx "${7-}" \
      '. + [ ($oa|if .=="" then {} else {open_alerts: (.|tonumber)} end)
             + ($mx|if .=="" then {} else {max_severity: .} end)
             + {feature:$f, state:$st, applicable:$ap, severity:$sev, enable_command:$cmd} ]' \
      <<<"$features")"
  }

  # ---- 1. Dependabot alerts (free on any repo) ----
  local da_state da_cmd="gh api -X PUT repos/$R/vulnerability-alerts"
  if runner gh api "repos/$R/vulnerability-alerts" --silent >/dev/null 2>&1; then
    da_state="on"
  else
    # 404 = disabled (the normal case). A timeout/auth failure also lands here; we
    # can't distinguish without the body, so treat as "off" but it'll be re-checked
    # below only if on. Conservative: report off (never a false "on").
    da_state="off"
  fi
  if [ "$da_state" = "on" ]; then
    # Enabled -> fetch OPEN alerts for real exposure. 403/404 -> n/a couldn't read.
    local da_json da_n da_max=""
    da_json="$(runner gh api "repos/$R/dependabot/alerts?state=open&per_page=100" 2>/dev/null)"
    if [ -n "$da_json" ] && printf '%s' "$da_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
      da_n="$(printf '%s' "$da_json" | jq 'length')"
      da_max="$(printf '%s' "$da_json" | jq -r '
        ([.[].security_advisory.severity] | map(ascii_downcase)) as $s
        | (["critical","high","medium","low"] | map(select(. as $t | $s | index($t))) | .[0]) // ""')"
      add "dependabot_alerts" "on" true "none" "$da_cmd" "$da_n" "$da_max"
    else
      add "dependabot_alerts" "on" true "none" "$da_cmd" "" "unknown"
    fi
  else
    add "dependabot_alerts" "off" true "$( [ "$is_public" -eq 1 ] && echo high || echo high )" "$da_cmd"
  fi

  # ---- 2. Dependabot security updates (free on any repo) ----
  local asf asf_cmd="gh api -X PUT repos/$R/automated-security-fixes"
  asf="$(runner gh api "repos/$R/automated-security-fixes" --jq '.enabled' 2>/dev/null | tr -d '\r')"
  case "$asf" in
    true)  add "dependabot_security_updates" "on"  true "none" "$asf_cmd" ;;
    false) add "dependabot_security_updates" "off" true "medium" "$asf_cmd" ;;
    *)     add "dependabot_security_updates" "unknown" true "low" "$asf_cmd" ;;
  esac

  # ---- 3. Secret scanning (free on public; GHAS on private) ----
  local ss_cmd='gh api -X PATCH repos/'"$R"' --input - <<<'"'"'{"security_and_analysis":{"secret_scanning":{"status":"enabled"}}}'"'"
  if [ "$scan_applicable" -eq 1 ]; then
    if [ "$ss" = "enabled" ]; then
      # On -> count open secret-scanning alerts. 403/404 -> couldn't read.
      local sj sn
      sj="$(runner gh api "repos/$R/secret-scanning/alerts?state=open&per_page=100" 2>/dev/null)"
      if [ -n "$sj" ] && printf '%s' "$sj" | jq -e 'type=="array"' >/dev/null 2>&1; then
        sn="$(printf '%s' "$sj" | jq 'length')"
        # Any exposed secret is critical.
        local sev=none; [ "$sn" -gt 0 ] && sev=critical
        add "secret_scanning" "on" true "$sev" "$ss_cmd" "$sn"
      else
        add "secret_scanning" "on" true "none" "$ss_cmd" "" "unknown"
      fi
    else
      add "secret_scanning" "off" true "medium" "$ss_cmd"
    fi
  else
    add "secret_scanning" "n/a" false "note" "$ss_cmd"
  fi

  # ---- 4. Push protection (free on public; GHAS on private). Needs secret scanning first. ----
  local pp_cmd='gh api -X PATCH repos/'"$R"' --input - <<<'"'"'{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'"'"
  if [ "$scan_applicable" -eq 1 ]; then
    if [ "$ssp" = "enabled" ]; then
      add "secret_scanning_push_protection" "on" true "none" "$pp_cmd"
    else
      add "secret_scanning_push_protection" "off" true "high" "$pp_cmd"
    fi
  else
    add "secret_scanning_push_protection" "n/a" false "note" "$pp_cmd"
  fi

  # ---- 5. Code scanning default setup (free on public; GHAS on private) ----
  local cs_state cs_cmd="gh api -X PUT repos/$R/code-scanning/default-setup -f state=configured"
  cs_state="$(runner gh api "repos/$R/code-scanning/default-setup" --jq '.state' 2>/dev/null | tr -d '\r')"
  if [ "$scan_applicable" -eq 1 ]; then
    if [ "$cs_state" = "configured" ]; then
      local cj cn cmax=""
      cj="$(runner gh api "repos/$R/code-scanning/alerts?state=open&per_page=100" 2>/dev/null)"
      if [ -n "$cj" ] && printf '%s' "$cj" | jq -e 'type=="array"' >/dev/null 2>&1; then
        cn="$(printf '%s' "$cj" | jq 'length')"
        cmax="$(printf '%s' "$cj" | jq -r '
          ([.[].rule.security_severity_level // .[].rule.severity // empty] | map(ascii_downcase)) as $s
          | (["critical","high","medium","low"] | map(select(. as $t | $s | index($t))) | .[0]) // ""')"
        add "code_scanning" "on" true "none" "$cs_cmd" "$cn" "$cmax"
      else
        add "code_scanning" "on" true "none" "$cs_cmd" "" "unknown"
      fi
    elif [ -n "$cs_state" ] && [ "$cs_state" != "null" ]; then
      add "code_scanning" "off" true "medium" "$cs_cmd"   # not-configured
    else
      add "code_scanning" "unknown" true "low" "$cs_cmd"  # couldn't read
    fi
  else
    add "code_scanning" "n/a" false "note" "$cs_cmd"
  fi

  # ---- 6. Private vulnerability reporting (free on any repo) ----
  local pvr pvr_cmd="gh api -X PUT repos/$R/private-vulnerability-reporting"
  pvr="$(runner gh api "repos/$R/private-vulnerability-reporting" --jq '.enabled' 2>/dev/null | tr -d '\r')"
  case "$pvr" in
    true)  add "private_vulnerability_reporting" "on"  true "none" "$pvr_cmd" ;;
    false) add "private_vulnerability_reporting" "off" true "low"  "$pvr_cmd" ;;
    *)     add "private_vulnerability_reporting" "unknown" true "low" "$pvr_cmd" ;;
  esac

  # ---- 7. SECURITY.md present (root, .github/, docs/) ----
  local sec_found=0 loc
  for loc in "SECURITY.md" ".github/SECURITY.md" "docs/SECURITY.md"; do
    if runner gh api "repos/$R/contents/$loc" --silent >/dev/null 2>&1; then sec_found=1; break; fi
  done
  local sec_cmd="cp assets/SECURITY.md.template SECURITY.md  # edit, commit, push"
  if [ "$sec_found" -eq 1 ]; then
    add "security_policy" "on" true "none" "$sec_cmd"
  else
    add "security_policy" "off" true "low" "$sec_cmd"
  fi

  # ---- 8. Branch protection on the default branch (bonus) ----
  local bp_cmd="# branch protection: see github.com/$R/settings/branches (requires a ruleset/protection JSON)"
  if runner gh api "repos/$R/branches/$default_branch/protection" --silent >/dev/null 2>&1; then
    add "branch_protection" "on" true "none" "$bp_cmd"
  else
    # 404 not-protected / 403 no-access -> treat as off (free to set on any repo).
    add "branch_protection" "off" true "medium" "$bp_cmd"
  fi

  # Assemble the repo object and decide the per-repo exit.
  local obj
  obj="$(jq -c -n --arg repo "$R" --arg vis "$vis" --argjson priv "${priv:-false}" \
    --arg ghas "$ghas" --argjson feat "$features" \
    '{repo:$repo, visibility:$vis, private:$priv,
      ghas:(if $ghas=="null" then null else $ghas end), features:$feat}')"
  printf '%s' "$obj"

  # Findings = any applicable feature that is off/unknown, OR any open_alerts>0.
  local gaps
  gaps="$(printf '%s' "$obj" | jq '
    [ .features[]
      | select(.applicable == true)
      | select( (.state=="off") or (.state=="unknown") or ((.open_alerts // 0) > 0) )
    ] | length')"
  [ "$gaps" -gt 0 ] && return 10
  return 0
}

# Severity glyph helper for human output.
sev_tag() { case "$1" in
  critical) printf '[critical]';; high) printf '[high]';;
  medium) printf '[medium]';; low) printf '[low]';;
  note) printf '';; *) printf '';; esac; }

# Human checklist for one repo object (reads JSON on stdin-arg $1).
print_human() { # repo_json
  local o="$1" repo vis
  repo="$(printf '%s' "$o" | jq -r '.repo')"
  vis="$(printf '%s' "$o" | jq -r '.visibility')"
  local hgaps health
  hgaps="$(printf '%s' "$o" | jq '[.features[]|select(.applicable==true and ((.state=="off") or (.state=="unknown") or ((.open_alerts//0)>0)))]|length')"
  if [ "$hgaps" -gt 0 ]; then health="$(term_health warning "$hgaps gap(s)/alert(s)")"; else health="$(term_health healthy clean)"; fi
  {
    term_panel_open github-ops "SECURITY POSTURE" "$repo  $vis"
    term_panel_vert
    while IFS= read -r ln; do term_panel_line "$ln"; done < <(printf '%s' "$o" | jq -r \
      --arg ok "$(term_mark ok)" --arg bad "$(term_mark bad)" \
      --arg na "$(term_mark na)" --arg unk "$(term_mark unknown)" '
      .features[] |
      if .state=="on" then
        "\($ok) \(.feature)" +
          (if (.open_alerts // 0) > 0 then "  — \(.open_alerts) OPEN alert(s)" + (if .max_severity then ", max \(.max_severity)" else "" end) else "" end) +
          (if .max_severity=="unknown" then "  (alerts: couldn’t read — needs security_events scope)" else "" end)
      elif .state=="n/a" then
        "\($na) \(.feature)  n/a (needs GitHub Advanced Security on a private repo)"
      elif .state=="unknown" then
        "\($unk) \(.feature)  n/a (couldn’t read)"
      else
        "\($bad) \(.feature)  [\(.severity)]"
      end')
    # Enable commands for gaps.
    local has_gap
    has_gap="$(printf '%s' "$o" | jq '[.features[]|select(.applicable==true and (.state=="off"))]|length')"
    if [ "$has_gap" -gt 0 ]; then
      term_panel_vert
      term_section "" "enable commands" "$has_gap"
      while IFS= read -r ln; do term_panel_line "$(term_color dim "$ln")"; done < <(printf '%s' "$o" | jq -r '.features[]|select(.applicable==true and .state=="off")|.enable_command')
    fi
    term_panel_vert
    term_panel_close "$(term_color dim "review before running    this script never runs them")" "$health"
  } >&2
}

# Emit ONLY the enable commands (data on stdout; banner on stderr).
print_commands() { # repo_json
  local o="$1"
  echo "# review before running — these change repo settings" >&2
  printf '%s' "$o" | jq -r '.features[]|select(.applicable==true and .state=="off")|.enable_command'
}

# ==========================================================================
# Mode dispatch
# ==========================================================================

# Conflicting selectors.
sel=0
[ -n "$REPO" ] && sel=$((sel+1))
[ -n "$ORG" ]  && sel=$((sel+1))
if [ "$sel" -gt 1 ]; then
  echo "check-security-posture: --repo and --org are mutually exclusive" >&2; exit "$EX_USAGE"
fi

# ---- Fleet sweep ----
if [ -n "$ORG" ]; then
  valid_owner "$ORG" || { echo "check-security-posture: invalid owner '$ORG'" >&2; exit "$EX_USAGE"; }
  list="$(runner gh repo list "$ORG" --no-archived --limit 200 --json nameWithOwner 2>/dev/null)" \
    || skip "gh repo list failed for $ORG (not authed / offline / rate-limited?)"
  [ -n "$list" ] || skip "no repos returned for $ORG"
  mapfile -t repos < <(printf '%s' "$list" | jq -r '.[].nameWithOwner' | tr -d '\r')
  [ "${#repos[@]}" -gt 0 ] || skip "no non-archived repos for $ORG"

  human=0; [ "$JSON" -eq 0 ] && [ "$COMMANDS" -eq 0 ] && human=1
  [ "$human" -eq 1 ] && { term_panel_open github-ops "SECURITY POSTURE" "$ORG  fleet sweep" >&2; term_panel_vert >&2; }

  all="[]"; any_findings=0; swept=0; unread=0
  for r in "${repos[@]}"; do
    valid_repo "$r" || continue
    obj="$(audit_repo "$r")"; rc=$?
    if [ "$rc" -eq 7 ] || [ -z "$obj" ]; then
      unread=$((unread+1))
      [ "$human" -eq 1 ] && term_panel_line "$(term_mark unknown) $r — couldn't read (skipped)" >&2
      continue
    fi
    swept=$((swept+1))
    [ "$rc" -eq 10 ] && any_findings=1
    all="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$all")"
    if [ "$human" -eq 1 ]; then
      gaps="$(printf '%s' "$obj" | jq '[.features[]|select(.applicable==true and ((.state=="off") or (.state=="unknown") or ((.open_alerts//0)>0)))]|length')"
      vis="$(printf '%s' "$obj" | jq -r '.visibility')"
      if [ "$gaps" -eq 0 ]; then term_panel_line "$(term_mark ok) $r ($vis) — clean" >&2
      else term_panel_line "$(term_mark bad) $r ($vis) — $gaps gap(s)/alert(s)" >&2; fi
    fi
  done

  if [ "$JSON" -eq 1 ]; then
    jq -c -n --argjson data "$all" --arg org "$ORG" \
      --argjson swept "$swept" --argjson unread "$unread" --argjson find "$any_findings" \
      '{data:$data, meta:{org:$org, repos_audited:$swept, repos_unreadable:$unread, findings:($find==1), schema:"claude-mods.github-ops.security-posture/v1"}}'
  elif [ "$COMMANDS" -eq 1 ]; then
    echo "# review before running — these change repo settings" >&2
    printf '%s' "$all" | jq -r '.[] | "# \(.repo)", (.features[]|select(.applicable==true and .state=="off")|"  \(.enable_command)")'
  else
    local_health="$([ "$any_findings" -eq 1 ] && term_health warning "$swept swept  gaps found" || term_health healthy "$swept swept  all clean")"
    term_panel_vert >&2
    term_panel_close "$(term_color dim "$unread unreadable")" "$local_health" >&2
  fi
  [ "$any_findings" -eq 1 ] && exit "$EX_FINDINGS"
  exit "$EX_OK"
fi

# ---- Single repo ----
if [ -z "$REPO" ]; then
  url="$(git remote get-url "$REMOTE" 2>/dev/null)" || skip "no '$REMOTE' remote here"
  case "$url" in
    *github.com[:/]*)
      REPO="$(printf '%s' "$url" | tr -d '\r' | sed -E 's#^.*github\.com[:/]+##; s#\.git$##; s#/$##')" ;;
    *) skip "remote '$REMOTE' is not a github.com repo" ;;
  esac
fi
valid_repo "$REPO" || { echo "check-security-posture: invalid OWNER/REPO '$REPO'" >&2; exit "$EX_USAGE"; }

obj="$(audit_repo "$REPO")"; rc=$?
if [ "$rc" -eq 7 ] || [ -z "$obj" ]; then skip "couldn't read $REPO (not authed / offline / not found / timeout)"; fi

if [ "$JSON" -eq 1 ]; then
  printf '%s' "$obj" | jq -c \
    '{data: .features, meta: {repo:.repo, visibility:.visibility, private:.private, ghas:.ghas,
        gaps: ([.features[]|select(.applicable==true and ((.state=="off") or (.state=="unknown")))]|length),
        open_alerts: ([.features[].open_alerts // 0]|add),
        schema:"claude-mods.github-ops.security-posture/v1"}}'
elif [ "$COMMANDS" -eq 1 ]; then
  print_commands "$obj"
else
  print_human "$obj"
fi

[ "$rc" -eq 10 ] && exit "$EX_FINDINGS"
exit "$EX_OK"
