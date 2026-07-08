# _env.sh - PATH self-heal sourced by every fleetflow entry script.
#
# WHY: GUI-launched hosts (Claude Desktop et al.) snapshot their environment
# at app start, so User-PATH entries added later by installers (winget, npm,
# scoop, pipx, uv) are invisible to child shells until the host restarts.
# Sessions then fail with "claude/jq/keyring not found" despite correct
# installs. This block re-adds the canonical per-user tool dirs when present.
# Extend via FLEETFLOW_PATH_PREPEND (colon-separated) for exotic locations.
for _ffd in ${FLEETFLOW_PATH_PREPEND:+$(echo "$FLEETFLOW_PATH_PREPEND" | tr ':' ' ')} \
            "$HOME/.local/bin" \
            "$HOME/AppData/Local/Microsoft/WinGet/Links" \
            "$HOME/AppData/Roaming/npm" \
            "$HOME/scoop/shims" \
            "$HOME/AppData/Local/Programs/Python/Python313/Scripts" \
            "$HOME/AppData/Roaming/Python/Python313/Scripts" \
            "$HOME/.local/share/uv/tools" ; do
  [ -d "$_ffd" ] && case ":$PATH:" in *":$_ffd:"*) ;; *) PATH="$_ffd:$PATH" ;; esac
done
unset _ffd
export PATH
