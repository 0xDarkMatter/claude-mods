# Credentials: one key per process, nothing in argv, nothing left on the box

Provider-neutral rules for API keys, plus each provider's variables. Per-provider sources
are in the cards; tags as there.

## The three rules

1. **One key per process; never switch the machine login.** Every CLI here keeps one
   stored login per user, shared by every shell and session on the machine. `boat login`,
   `e2b auth login`, `daytona login` or `fly auth login` for a second company rewrites
   it under everyone. Put the key in the job's own environment instead, which every
   provider supports, with the two notes in the table.
2. **Nothing in argv.** Other users on a host can read process arguments, and shells log
   them. Pass a key on stdin, in the environment, or from a file read by the tool; never
   as a flag value (`--token`, `--api-key`, `--key`) or inside an exec string. A share
   code that grants a box (boat's `bsh_...`) counts as a key.
3. **No credentials left on the box.** A box is readable by everything on it (see
   [security-and-residency](security-and-residency.md)). Prefer credentials that never
   enter it: Vercel's firewall injection, a git bundle instead of a clone with a token,
   results pulled home rather than pushed from the box.

Check which account a key bills before any work: an org key and a personal key look the
same, and nothing on a box says whose it is.

## Per-provider variables

| Provider | Variable(s) | Beats the stored login? |
|---|---|---|
| boat | `BOAT_API_KEY` | Yes, measured on `status` and `org list`; `ssh`/`scp` use per-account SSH keys, not tested |
| E2B | `E2B_API_KEY` (`E2B_DOMAIN` picks the region) | The CLI works on the variable alone from 2.12.1; that it beats `~/.e2b/config.json` is from the CLI source, not the docs |
| Modal | `MODAL_TOKEN_ID` + `MODAL_TOKEN_SECRET` | Yes: `MODAL_<SETTING>` overrides the active `.modal.toml` profile; `MODAL_CONFIG_PATH` moves the file |
| Vercel | SDK: `VERCEL_TOKEN` + `VERCEL_TEAM_ID` + `VERCEL_PROJECT_ID`, or `VERCEL_OIDC_TOKEN` (12 h) | `vercel` reads `VERCEL_TOKEN`; the standalone `sandbox` CLI is undocumented on it: use the SDK or `vercel sandbox` |
| Daytona | `DAYTONA_API_KEY` **and** `DAYTONA_API_URL` | Only when both are set; or give the process its own `DAYTONA_CONFIG_DIR` |
| Fly | `FLY_API_TOKEN` (`FLY_ACCESS_TOKEN` wins if both set) | Yes; scoped tokens default to a 20-year expiry, so pass `--expiry` |

## Testing that a variable wins

Before trusting a provider for unattended work, run one read-only command twice: once
with the machine login only, once with a second account's key in the environment, and
compare the account each reports. It is the one check the docs could not settle for E2B
and Vercel's standalone CLI.
