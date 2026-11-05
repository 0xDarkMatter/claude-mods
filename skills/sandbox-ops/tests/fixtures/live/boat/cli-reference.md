<!-- Recorded excerpt of https://docs.boat.dev/cli-reference.md, fetched 2026-10-27. Test input for check-boat-facts.py --live --fixtures; lines are verbatim, the rest of the page is cut. -->
# CLI reference

To update, run `boat self-update`. The CLI also updates itself, at most every 6 hours, after a command ends. It never asks a question and never changes a command that runs. To keep one version for a whole script or benchmark, set `BOAT_NO_UPDATE=1` or pass `--no-update`.

| `--json` | Print JSON for machines instead of text for people |
boat new [--ttl SECONDS]
| `--type` | `default` (the medium size) | `small`, `default`, `large` or `xlarge` (`xlarge` needs the \$100 plan or higher) |
| `--ttl` | `3600` (1 hour): seconds until auto-stop, counted from start or resume. It is not an idle timeout: only a running Boat agent prompt pushes it back, not `boat exec` or SSH. | `2592000` (30 days) |
| `--no-env` | off | none |
| `--no-snapshots` | off | none |
| `--no-monitoring` | off | none |
| `--fail-fast` | off | none |
| `--setup-file` | none | 64KB script file |
| `--name` | `Box <date>`, or the snapshot name with `--from` | 120 characters |
boat list --all
boat delete bx_f7k2q9hd --yes
| `--timeout <secs>` | `30` | Stop the command after this many seconds and exit `124`. `0` = no limit. Above `600`, or `0`, the output streams live |
| `--detach` | off | Run in the background and print the process id |
| `--status <pid>` | none | Show status and logs of a process started with `--detach` |
| `--kill <pid>` | none | Stop a process started with `--detach`, and every process it started |
| `--attach <pid>` | none | Print the output of a process started with `--detach` as it writes it, from its start, until it ends. Exits with its exit code. Reconnects every 10 minutes with no gap |
