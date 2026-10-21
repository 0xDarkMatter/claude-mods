#!/bin/bash
# hooks/pre-tls-verify-ask.sh
# PreToolUse hook (matcher: Bash|PowerShell) - ask before a command turns TLS
# certificate verification off.
#
# Why: at a certificate error an agent tends to switch verification off (curl -k,
# NODE_TLS_REJECT_UNAUTHORIZED=0, git -c http.sslVerify=false) and carry on without
# saying so. Then anyone on the network path can impersonate the server and read or
# change the traffic, credentials included, and a tampered package or download walks
# in. rules/supply-chain.md: a certificate error is a stop-and-report.
#
# Why ASK, never deny: a self-signed certificate on a local development host is the
# one legitimate case, and only the user knows whether this is it. An ask costs
# nothing unless one of the switches below is present.
#
# What asks (each one is a case in tests/hooks.sh):
#   curl -k / -sSk / --insecure / --proxy-insecure   wget --no-check-certificate
#   NODE_TLS_REJECT_UNAUTHORIZED=0  PYTHONHTTPSVERIFY=0  GIT_SSL_NO_VERIFY=<any value>
#   npm_config_strict_ssl=false  yarn_enable_strict_ssl=false
#   PIP_TRUSTED_HOST=..  UV_INSECURE_HOST=..   (bash prefix/export, cmd set, $env:)
#   git -c http.sslVerify=false              git config http.sslVerify false     (*)
#   npm/pnpm/yarn --strict-ssl=false         npm/pnpm/yarn config set strict-ssl false,
#                                            yarn config set enableStrictSsl false (*)
#   pip/uv --trusted-host, --allow-insecure-host     pip config set *.trusted-host (*)
#   composer config disable-tls true / secure-http false                         (*)
#   setx <one of the variables above> <value>                                    (*)
#   PowerShell -SkipCertificateCheck, ServerCertificateValidationCallback = {$true},
#   [ServicePointManager]::CertificatePolicy = <custom policy>
#   (*) persistent: the reason says the switch outlives the session.
#
# Command position. curl, wget, git, npm, pip, composer and setx count only as the
# command word of a segment: after a line start, ; & | ( ) { } or a backtick, after
# a keyword (if/then/do/...), NAME=value prefixes, and wrappers (sudo, env, xargs,
# nohup, nice, time, timeout, watch, exec, npx, cross-env, ...). The lexer is
# quote-aware, so `git commit -m "Drop curl -k"` and `rg 'wget|curl -k'` stay
# silent. Heredoc bodies are data unless the heredoc feeds a shell; the script of
# `bash -c '...'`, `pwsh -Command ...` and `cmd /c ...` is lexed as a command. An
# env assignment counts as one whole unquoted token, anywhere except in a search
# (rg/grep/findstr/Select-String), so a commit message that names one stays silent.
# Not followed: ssh / docker exec / find -exec arguments, $(...) inside "double
# quotes", PowerShell <# block comments #>.
#
# Output: one JSON value on stdout, exit 0:
#   hookSpecificOutput.permissionDecision "ask" + permissionDecisionReason (the user
#   reads it in the prompt; under `claude -p` nobody can answer, the call is denied
#   and Claude reads it) + additionalContext (Claude reads it beside the result).
# Silent (no output, exit 0) when nothing matches or jq is missing.
# https://code.claude.com/docs/en/hooks#pretooluse-decision-control
# Contract tests: tests/hooks.sh ("pre-tls-verify-ask").

set -u
export LC_ALL=C   # byte-wise strings and [[:alpha:]]; no multibyte walks
shopt -s extglob

# Guard: regexes live in variables, never inline after =~. Bash 3.2 (macOS) and
# bash 5 disagree on how backslashes and quotes inside an inline regex are read;
# a variable is passed to the regex engine as-is by every version.
# The pre-filter names every switch below, so a command that names none of them
# exits before jq or the lexer runs (nocase; `.` stands for - or _).
RE_PREFILTER='(curl|wget|sslverify|strict.?ssl|trusted.host|insecure.host|disable-tls|secure-http|NODE_TLS_REJECT|PYTHONHTTPSVERIFY|GIT_SSL_NO_VERIFY|SkipCertificateCheck|CertificateValidationCallback|CertificatePolicy)'
RE_ASSIGN='^[A-Za-z_][A-Za-z0-9_]*='
RE_ENV_ZERO='^(NODE_TLS_REJECT_UNAUTHORIZED|PYTHONHTTPSVERIFY)=0$'
RE_ENV_ANY='^GIT_SSL_NO_VERIFY='
RE_ENV_STRICT='^(npm_config_strict_ssl|yarn_enable_strict_ssl)=(false|0)$'
RE_ENV_HOST='^(PIP_TRUSTED_HOST|UV_INSECURE_HOST)=.'
RE_SKIPCERT='^-SkipCertificateCheck(:[$]true)?$'
RE_PYTHON='^(python[0-9.]*|py)$'
RE_PIPMOD='^pip[0-9.]*$'
RE_CURL_K='^-[A-Za-z]*k[A-Za-z]*$'        # case-sensitive: -K is --config
RE_GIT_C='^http[.](.+[.])?sslverify=(false|no|off|0)$'
RE_GIT_KEY='^http[.](.+[.])?sslverify$'
RE_FALSY='^(false|no|off|0)$'
RE_NPM_FLAG='^--strict-ssl=(false|0)$'
RE_NPM_KV='^(strict-ssl|enableStrictSsl)=(false|0)$'
RE_NPM_KEY='^(strict-ssl|enableStrictSsl)$'
RE_FALSE0='^(false|0)$'
RE_TRUE1='^(true|1)$'
RE_PIP_FLAG='^--(trusted-host|allow-insecure-host)(=.*)?$'
RE_PIP_KEY='trusted-host$'
RE_SH_C='^-[A-Za-z]*c[A-Za-z]*$'           # -c, -lc, -ec
RE_PS_C='^-c(o(m(m(a(n(d)?)?)?)?)?)?$'      # -Command and its prefixes (nocase)
RE_CMD_C='^/[ck]$'
RE_DOTNET_CB='ServerCertificateValidationCallback[[:space:]]*[+]?=[[:space:]]*([[][^]]*[]][[:space:]]*)?[{][[:space:]]*(return[[:space:]]+)?[$]true'
RE_DOTNET_POLICY='ServicePointManager[]]::CertificatePolicy[[:space:]]*='
RE_HEREDOC="(^|[^<])<<(-?)[[:space:]]*[\"']?([A-Za-z0-9_.-]+)"
RE_HERESTRING="@([\"'])[[:space:]]*\$"
RE_DOC_PREFIX='^([A-Za-z_][A-Za-z0-9_]*=.*|sudo|env|exec|command|nohup|time|-.*)$'
RE_SHELL='^(bash|sh|zsh|dash|ksh|ash|pwsh|powershell)$'

TOOL="Bash"; CMD=""; RAW=""
if [[ $# -gt 0 && -n "${1:-}" ]]; then
  CMD="$1"; RAW="$1"
elif [[ ! -t 0 ]]; then
  IFS= read -r -d '' RAW || true
fi
[[ -z "$RAW" ]] && exit 0

# Cheap pre-filter on the raw payload, no fork: almost every command stops here.
shopt -s nocasematch
[[ "$RAW" =~ $RE_PREFILTER ]] || exit 0
shopt -u nocasematch

command -v jq >/dev/null 2>&1 || exit 0   # no jq: cannot parse or answer - stay silent
if [[ -z "$CMD" ]]; then
  # Line 1 = tool name, the rest = the command (it may span lines).
  out="$(printf '%s' "$RAW" | jq -r '(.tool_name // "Bash"), (.tool_input.command // "")' 2>/dev/null)" || exit 0
  out="${out//$'\r'/}"   # Windows jq.exe writes -r output in text mode (\r\n)
  TOOL="${out%%$'\n'*}"
  if [[ "$out" == *$'\n'* ]]; then CMD="${out#*$'\n'}"; fi
fi
CMD="${CMD//$'\r'/}"
[[ -z "$CMD" ]] && exit 0

HITS=""      # matched labels, one per line, deduplicated
PERSIST=0    # 1 when a match writes the switch somewhere that outlives the session

hit() {   # $1 label, $2 = 1 when persistent
  case $'\n'"$HITS" in *$'\n'"$1"$'\n'*) ;; *) HITS+="$1"$'\n' ;; esac
  [[ "${2:-0}" == 1 ]] && PERSIST=1
  return 0
}

# Command name into CN (a global, not $(...): every subshell is a fork, and forks
# are what make a hook slow under Git Bash). /usr/bin/curl, curl.exe, \curl -> curl
cmd_name() {
  CN="${1##*[/\\]}"
  CN="${CN%.[eE][xX][eE]}"; CN="${CN%.[cC][mM][dD]}"; CN="${CN%.[bB][aA][tT]}"
}

# --- an env assignment carried by one token ------------------------------------
# $1 "NAME=VALUE", "$env:NAME=VALUE" or "--env=NAME=VALUE"; $2 = 1 when persistent.
env_token() {
  local t="$1"
  t="${t#\$[eE][nN][vV]:}"
  [[ "$t" == -*=*=* ]] && t="${t#*=}"
  shopt -s nocasematch
  if [[ "$t" =~ $RE_ENV_ZERO ]]; then
    hit "${BASH_REMATCH[1]}=0" "${2:-0}"
  elif [[ "$t" =~ $RE_ENV_ANY ]]; then
    # git turns verification off when the variable is set at all, even to 0 or "".
    hit "GIT_SSL_NO_VERIFY" "${2:-0}"
  elif [[ "$t" =~ $RE_ENV_STRICT ]]; then
    hit "${BASH_REMATCH[1]}=false" "${2:-0}"
  elif [[ "$t" =~ $RE_ENV_HOST ]]; then
    hit "${BASH_REMATCH[1]}" "${2:-0}"
  fi
  shopt -u nocasematch
}

# --- one segment: a command word and its arguments -------------------------------
# $1 mode (sh|ps), $2 depth, rest = the segment's unquoted tokens.
check_segment() {
  local mode="$1" depth="$2"; shift 2
  local -a w=("$@")
  local n=${#w[@]} i=0 k f t b key

  # Find the command word: skip keywords, NAME=value prefixes and wrappers.
  while (( i < n )); do
    t="${w[i]}"
    if [[ "$t" =~ $RE_ASSIGN ]]; then i=$((i + 1)); continue; fi
    cmd_name "$t"
    case "$CN" in
      if|then|elif|else|do|while|until|'!'|time|nohup|command|builtin|exec|nice|stdbuf|\
      corepack|npx|cross-env|xargs|sudo|doas|env|watch|timeout)
        b="$CN"; i=$((i + 1))
        while (( i < n )) && [[ "${w[i]}" == -* ]]; do
          f="${w[i]}"; i=$((i + 1))
          case "$b:$f" in   # flags that take the next token as their value
            sudo:-[ugUCprtD]|doas:-[uC]|env:-[uCS]|xargs:-[ILPnsdaE]|nice:-n|watch:-n|\
            timeout:-[sk]|stdbuf:-[ioe]|exec:-a|time:-[fo]|npx:-p|npx:--package)
              i=$((i + 1)) ;;
          esac
        done
        [[ "$b" == timeout ]] && (( i < n )) && i=$((i + 1))   # the duration
        continue ;;
    esac
    break
  done

  b=""
  if (( i < n )); then cmd_name "${w[i]}"; b="$CN"; fi
  case "$b" in
    rg|grep|egrep|fgrep|ag|ack|findstr|sls|[Ss]elect-[Ss]tring) return 0 ;;   # a search pattern is data
  esac

  # Env assignments (one token, or PowerShell's spaced `$env:NAME = value`) and
  # PowerShell's -SkipCertificateCheck on whichever cmdlet carries it. The globs
  # keep the regexes off the many tokens that cannot match.
  for ((k = 0; k < n; k++)); do
    t="${w[k]}"
    if [[ "${w[k+1]:-}" == "=" && "$t" == \$[eE][nN][vV]:* ]]; then t="$t=${w[k+2]:-}"; fi
    case "$t" in
      *[Tt][Ll][Ss]_[Rr]*=*|*[Hh][Tt][Tt][Pp][Ss][Vv]*=*|*[Ss][Ss][Ll]_*=*|*_[Ss][Ss][Ll]=*|*[Hh][Oo][Ss][Tt]=*)
        env_token "$t" 0 ;;
      -[Ss][Kk][Ii][Pp]*)
        shopt -s nocasematch
        [[ "$t" =~ $RE_SKIPCERT ]] && hit "-SkipCertificateCheck"
        shopt -u nocasematch ;;
    esac
  done
  (( i < n )) || return 0

  # python -m pip ... counts as pip.
  if [[ "$b" =~ $RE_PYTHON && "${w[i+1]:-}" == -m && "${w[i+2]:-}" =~ $RE_PIPMOD ]]; then
    b=pip; i=$((i + 2))
  fi

  case "$b" in
    curl)
      for ((k = i + 1; k < n; k++)); do
        t="${w[k]}"
        if [[ "$t" =~ $RE_CURL_K ]]; then hit "curl -k"
        elif [[ "$t" == --insecure || "$t" == --proxy-insecure ]]; then hit "curl $t"; fi
      done ;;
    wget|wget2)
      for ((k = i + 1; k < n; k++)); do
        [[ "${w[k]}" == --no-check-certificate ]] && hit "wget --no-check-certificate"
      done ;;
    git)
      shopt -s nocasematch   # git config keys and boolean values are case-insensitive
      for ((k = i + 1; k < n; k++)); do
        t="${w[k]}"
        if [[ "$t" == -c && "${w[k+1]:-}" =~ $RE_GIT_C ]]; then
          hit "git -c http.sslVerify=false"
        elif [[ "$t" == config ]]; then
          for ((f = k + 1; f < n; f++)); do
            if [[ "${w[f]}" =~ $RE_GIT_KEY && "${w[f+1]:-}" =~ $RE_FALSY ]]; then
              hit "git config http.sslVerify false" 1
            fi
          done
        fi
      done
      shopt -u nocasematch ;;
    npm|pnpm|yarn)
      shopt -s nocasematch
      for ((k = i + 1; k < n; k++)); do
        t="${w[k]}"
        if [[ "$t" =~ $RE_NPM_FLAG || "$t" == --no-strict-ssl ]] \
           || [[ "$t" == --strict-ssl && "${w[k+1]:-}" =~ $RE_FALSE0 ]]; then
          hit "$b --strict-ssl=false"
        elif [[ "$t" == config && "${w[k+1]:-}" == set ]]; then
          f=$((k + 2))
          while (( f < n )) && [[ "${w[f]}" == -* ]]; do f=$((f + 1)); done
          key=""
          if [[ "${w[f]:-}" =~ $RE_NPM_KV ]]; then key="${BASH_REMATCH[1]}"
          elif [[ "${w[f]:-}" =~ $RE_NPM_KEY ]]; then
            key="${BASH_REMATCH[1]}"
            [[ "${w[f+1]:-}" =~ $RE_FALSE0 ]] || key=""
          fi
          [[ -n "$key" ]] && hit "$b config set $key false" 1
        fi
      done
      shopt -u nocasematch ;;
    pip|pip[0-9]*|uv)
      for ((k = i + 1; k < n; k++)); do
        t="${w[k]}"
        if [[ "$t" =~ $RE_PIP_FLAG ]]; then
          hit "$b --${BASH_REMATCH[1]}"
        elif [[ "$t" == config ]]; then
          # pip config [--global] set global.trusted-host <host>
          for ((f = k + 1; f < n; f++)); do
            if [[ "${w[f]}" == set && "${w[f+1]:-}" =~ $RE_PIP_KEY ]]; then
              hit "pip config set trusted-host" 1
            fi
          done
        fi
      done ;;
    composer)
      shopt -s nocasematch
      for ((k = i + 1; k < n; k++)); do
        [[ "${w[k]}" == config ]] || continue
        for ((f = k + 1; f < n; f++)); do
          if [[ "${w[f]}" == disable-tls && "${w[f+1]:-}" =~ $RE_TRUE1 ]]; then
            hit "composer config disable-tls true" 1
          elif [[ "${w[f]}" == secure-http && "${w[f+1]:-}" =~ $RE_FALSE0 ]]; then
            hit "composer config secure-http false" 1
          fi
        done
      done
      shopt -u nocasematch ;;
    setx)
      # setx NAME VALUE [/M] writes the user (or machine) environment for good.
      for ((k = i + 1; k < n; k++)); do
        [[ "${w[k]}" == /* ]] && continue
        env_token "${w[k]}=${w[k+1]:-}" 1
        break
      done ;;
    bash|sh|zsh|dash|ksh|ash)
      for ((k = i + 1; k < n; k++)); do
        if [[ "${w[k]}" =~ $RE_SH_C ]]; then
          (( depth < 3 )) && scan "${w[k+1]:-}" sh $((depth + 1))
          break
        fi
      done ;;
    pwsh|powershell)
      for ((k = i + 1; k < n; k++)); do
        shopt -s nocasematch
        if [[ "${w[k]}" =~ $RE_PS_C ]]; then
          shopt -u nocasematch
          (( depth < 3 )) && scan "${w[*]:k+1}" ps $((depth + 1))
          break
        fi
        shopt -u nocasematch
      done ;;
    cmd)
      for ((k = i + 1; k < n; k++)); do
        shopt -s nocasematch
        if [[ "${w[k]}" =~ $RE_CMD_C ]]; then
          shopt -u nocasematch
          (( depth < 3 )) && scan "${w[*]:k+1}" sh $((depth + 1))
          break
        fi
        shopt -u nocasematch
      done ;;
  esac
  return 0
}

# --- heredoc / here-string bodies are data ---------------------------------------
# $1 text, $2 mode; sets DOC_OUT to the text with data bodies blanked (newlines kept,
# so segments still end where they did). A bash heredoc stays code when the command
# before `<<` is a shell (`bash <<EOF`); a PowerShell here-string (@' ... '@) is
# always data. Works on raw lines: a `<<` inside quotes is taken as a heredoc too.
strip_docs() {
  local text="$1" mode="$2" line l delim="" tabs=0 keep=0 pre j
  local -a pw
  DOC_OUT=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$delim" ]]; then
      l="$line"; (( tabs )) && l="${l##+($'\t')}"
      if [[ "$mode" == ps && "$l" == "$delim"* ]]; then
        DOC_OUT+="${l#"$delim"}"$'\n'; delim=""; continue
      elif [[ "$mode" == sh && "$l" == "$delim" ]]; then
        DOC_OUT+=$'\n'; delim=""; continue
      fi
      if (( keep )); then DOC_OUT+="$line"$'\n'; else DOC_OUT+=$'\n'; fi
      continue
    fi
    DOC_OUT+="$line"$'\n'
    if [[ "$mode" == ps ]]; then
      if [[ "$line" =~ $RE_HERESTRING ]]; then delim="${BASH_REMATCH[1]}@"; tabs=0; keep=0; fi
    elif [[ "$line" =~ $RE_HEREDOC ]]; then
      delim="${BASH_REMATCH[3]}"; tabs=0; [[ -n "${BASH_REMATCH[2]}" ]] && tabs=1
      pre="${line%%"${BASH_REMATCH[0]}"*}${BASH_REMATCH[1]}"
      pre="${pre##*[;|&(]}"
      read -ra pw <<< "$pre"
      keep=0; j=0
      while (( j < ${#pw[@]} )) && [[ "${pw[j]}" =~ $RE_DOC_PREFIX ]]; do j=$((j + 1)); done
      if (( j < ${#pw[@]} )); then
        cmd_name "${pw[j]}"
        [[ "$CN" =~ $RE_SHELL ]] && keep=1
      fi
    fi
  done <<< "$text"
}

# --- the lexer ---------------------------------------------------------------------
# $1 text, $2 mode: sh (bash/cmd quoting, \ escapes) or ps (PowerShell, ` escapes),
# $3 depth. Splits into segments on unquoted ; & | ( ) { } ` and newlines and hands
# each to check_segment with its tokens unquoted. A word that starts with # runs to
# the end of the line (a comment). Reads at most the first 64 KiB.
#
# Guard: characters are read from a 512-byte window ($win, starting at offset $wb),
# never as ${s:i:1}, and a run of ordinary characters (or a quoted span) is taken
# in one step. Bash copies from the start of the string for every substring, so
# ${s:i:1} per character was quadratic: 3 s for a 24 KB command. The window starts
# one byte back so ${win:o-1:1} can look behind.
lex() {
  local s="$1" mode="$2" depth="$3" n=${#1} i=0 o=0 wb=0 W=512 win c nx q="" tok="" have=0 esc='\' rest pre
  local -a T=()
  # Run delimiters as glob brackets: unquoted, inside "double quotes".
  local p_unq="[[:space:];|(){}\`&'\"\$\\\\]" p_dq="[\"\\\\]"
  [[ "$mode" == ps ]] && { esc='`'; p_dq="[\"\`]"; }
  (( n > 65536 )) && n=65536
  win="${s:0:W}"
  while (( i < n )); do
    o=$((i - wb))
    if (( o >= W - 2 )); then wb=$((i - 1)); win="${s:wb:W}"; o=1; fi
    c="${win:o:1}"
    if [[ "$q" == "'" ]]; then
      if [[ "$c" == "'" ]]; then q=""
      else rest="${win:o}"; pre="${rest%%\'*}"; tok+="$pre"; i=$((i + ${#pre} - 1)); fi
    elif [[ "$q" == '"' ]]; then
      if [[ "$c" == "$esc" ]]; then
        nx="${win:o+1:1}"
        if [[ "$mode" == ps || "$nx" == [\$\`\"\\] ]]; then tok+="$nx"; i=$((i + 1))
        elif [[ "$nx" == $'\n' ]]; then i=$((i + 1))
        else tok+="$c"; fi
      elif [[ "$c" == '"' ]]; then q=""
      else rest="${win:o}"; pre="${rest%%$p_dq*}"; tok+="$pre"; i=$((i + ${#pre} - 1)); fi
    else
      case "$c" in
        "$esc")
          nx="${win:o+1:1}"; i=$((i + 1))
          [[ "$nx" == $'\n' ]] || { tok+="$nx"; have=1; } ;;
        "'"|'"') q="$c"; have=1 ;;
        ' '|$'\t')
          if (( have )); then T+=("$tok"); tok=""; have=0; fi ;;
        $'\n'|';'|'|'|'('|')'|'{'|'}'|'`')
          if (( have )); then T+=("$tok"); tok=""; have=0; fi
          (( ${#T[@]} )) && check_segment "$mode" "$depth" "${T[@]}"
          T=() ;;
        '&')
          # 2>&1, >&2 and &> are redirections, not separators.
          if (( o > 0 )) && [[ "${win:o-1:1}" == [\<\>] ]] || [[ "${win:o+1:1}" == '>' ]]; then
            tok+="$c"; have=1
          else
            if (( have )); then T+=("$tok"); tok=""; have=0; fi
            (( ${#T[@]} )) && check_segment "$mode" "$depth" "${T[@]}"
            T=()
          fi ;;
        '#')   # rare, so the O(n) ${s:i} copy here is fine
          if (( have )); then tok+="$c"
          else rest="${s:i}"; pre="${rest%%$'\n'*}"; i=$((i + ${#pre} - 1)); fi ;;
        '$')
          if [[ "${win:o+1:1}" == '{' ]]; then   # ${VAR} is one word, not a { } group
            rest="${s:i}"; pre="${rest%%\}*}"; tok+="${rest:0:${#pre}+1}"; i=$((i + ${#pre}))
          else tok+="$c"; fi
          have=1 ;;
        *)
          rest="${win:o}"; pre="${rest%%$p_unq*}"; [[ -n "$pre" ]] || pre="$c"
          tok+="$pre"; have=1; i=$((i + ${#pre} - 1)) ;;
      esac
    fi
    i=$((i + 1))
  done
  (( have )) && T+=("$tok")
  (( ${#T[@]} )) && check_segment "$mode" "$depth" "${T[@]}"
  return 0
}

scan() {   # $1 text, $2 mode (sh|ps), $3 depth
  local code="$1"
  if [[ "$1" == *'<<'* || ( "$2" == ps && "$1" == *@[\"\']* ) ]]; then
    strip_docs "$1" "$2"; code="$DOC_OUT"
  fi
  # .NET trust-all idioms: distinctive enough to match anywhere in the text.
  shopt -s nocasematch
  [[ "$code" =~ $RE_DOTNET_CB ]] && hit "ServerCertificateValidationCallback = { \$true }"
  [[ "$code" =~ $RE_DOTNET_POLICY ]] && hit "ServicePointManager CertificatePolicy"
  shopt -u nocasematch
  lex "$code" "$2" "$3"
}

MODE=sh; [[ "$TOOL" == PowerShell ]] && MODE=ps
scan "$CMD" "$MODE" 0
[[ -z "$HITS" ]] && exit 0

LIST="${HITS%$'\n'}"; LIST="${LIST//$'\n'/, }"
REASON="TLS GUARD: this turns TLS certificate verification off ($LIST). Anyone on the network path could then impersonate the server and read or change the traffic, credentials and downloads included. Allow it only for a self-signed certificate on a local development host."
CONTEXT="TLS GUARD: this command turns TLS certificate verification off ($LIST), so the user was asked first. A certificate error is a stop-and-report (rules/supply-chain.md): tell the user the error and the host, and do not look for another way past it. If they allowed it, say in your reply that verification was off for this call."
if (( PERSIST )); then
  REASON+=" It also writes the switch to a config file or the environment, so it outlives this session and applies to every later fetch until someone reverts it."
  CONTEXT+=" The switch persists beyond this session: name the file or setting so it can be reverted."
fi

# Guard: one JSON value and nothing else on stdout, built by jq (never by string
# concatenation), or Claude Code cannot parse the decision and the call runs with
# no prompt. An ask exits 0; exit 2 would be a deny.
jq -nc --arg r "$REASON" --arg c "$CONTEXT" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r,additionalContext:$c}}'
exit 0
