# Docker and DDEV on a box

Source tags as in SKILL.md. The Docker figures are build-only benchmarks of two client
PHP sites on `default` boxes, 5 runs each, 2026-10-27: no push, no registry login, no
secrets on the box [field]. The DDEV findings come from a DDEV v1.25.4 test on an Ubuntu
24.04 boat box with Docker Engine 29, 2026-10-27 [field].

## Docker

- Docker 29.7 and buildx come preinstalled [bench, field]. The daemon comes up a few
  seconds after the box reports ready [docs: llms.txt]; wait for `docker info`.
- Build with a fresh builder to match CI, which had no layer cache:
  `docker buildx create --name bench --use`, then
  `docker buildx build --builder bench --platform linux/amd64 --provenance=false --load --no-cache -f ./Dockerfile -t <tag> .`
- Measured: the build step took 10.7 s and 21.4 s (medians) on boat, against 28 s and
  50.5 s on GitHub's hosted runner, about 2.3-2.6x; the hosted figures mostly included the
  push [field]. boat had 4 vCPU against the private-repo runner's documented 2.
- **Composer without a token.** Hundreds of public `api.github.com` zipball downloads
  pass GitHub's anonymous limit of 60 an hour. A copy of `composer.lock` on the box was
  rewritten to the same archives on `codeload.github.com`, and the original restored
  before the build [field]. Five boxes fetching at once looked rate-shared, as through one
  NAT (inferred), which widened the composer times.
- **No `.dockerignore`** sends the whole tree to BuildKit: one site sent 480 MB, mostly
  `vendor/`, for a 220 MB image [field]. Check before blaming the box.
- Don't apply the CI capability drop (see [ci-runner](ci-runner.md#the-boxs-setup-script))
  to a Docker build: the build runs in the root daemon and needs the sudo and docker
  access the drop removes [field].
- Containers inside one box share its kernel; boat does not isolate them from each other
  [docs: security]. One box per tenant, never one box for several.
- A committed `.ddev/.env*` with local-only defaults rides along in the build context
  when there is no `.dockerignore`. Name the keys you find; never print the values.

## DDEV

DDEV runs on a box like on any Ubuntu host with Docker. Its agent-specific failures are
the same as on a desk, and `ddev-ops` owns them. What the box test found [field]:
- **Nested worktrees.** Since v1.25.4, `ddev start` in a worktree inside the main checkout
  (for example `.claude/worktrees/<name>`) quietly runs the MAIN checkout's project when
  there is no terminal, and every command exits 0. Put worktrees beside the checkout.
- **Parallel cold starts** failed on `network ... ddev_default already exists` in every
  cold run: start sites one at a time.
- **Telemetry.** An agent's first `ddev` command answers the usage-statistics question
  with yes. Set `ddev config global --instrumentation-opt-in=false` (or `true`) once,
  deliberately, at box setup.
- **Commands that look as if they ran.** With no terminal, `ddev ssh` and a bare
  `ddev mysql` do nothing and exit 0.
- **Data.** Seed boxes only with synthetic or mock data, never a production copy or a
  dump of one; no `ddev share` or `bind_all_interfaces` on a box an agent drives (a box
  is reachable through any port you publish).
- Delete the box when the task ends: removed worktrees otherwise leave DDEV database
  volumes behind, and a box is the cheapest place to make that someone else's problem.
