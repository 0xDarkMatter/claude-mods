# Destructive Commands: Tiers and an Index

One rule across Docker, Compose, Kubernetes, Helm and DDEV: **before anything that loses
data or state, say exactly what will be lost; for a Tier 2 command, wait for a yes.** The
tiers follow Docker's own agent guardrails (docker/skills), extended to the neighbouring
tools.

## Contents

- [The tiers](#the-tiers)
- [Docker and Compose](#docker-and-compose)
- [Kubernetes and Helm](#kubernetes-and-helm)
- [DDEV](#ddev)
- [How to ask](#how-to-ask)

## The tiers

| Tier | When | What you do |
|---|---|---|
| **1** | one named target, no unsaved state, an explicit ask from the user, or a throwaway you created this session for a test | act, then report what you removed |
| **2** | a sweep or prune; a target you didn't create; anything holding data (volumes, databases, PVCs, namespaces); anything you'd be doing on your own initiative | list what will be lost, ask, wait for a yes |
| **outside** | stop or scale down: restartable, but in-memory state and in-flight work go | warn, unless it is your own test container |

**Scope beats state.** A sweep is Tier 2 even when everything it touches is stopped:
`docker rm $(docker ps -aq)` removes containers the user may be about to restart. "They're
all stopped anyway" is not consent. A named single target is what makes Tier 1 possible.

## Docker and Compose

| Command | Tier | What is lost |
|---|---|---|
| `docker rm <container>` (stopped, named by the user) | 1 | the container's writable layer: anything written outside a volume |
| `docker rm -f <container>` you started this session | 1 | same, plus the running process |
| `docker kill` | 2 | the process, with no clean shutdown (no SIGTERM handling) |
| `docker container prune` | 2 | every stopped container on the engine, not just this project's |
| `docker image prune -a` / `system prune -a` | 2 | every image no container uses: the next builds re-download everything |
| `docker volume rm` / `volume prune -a` | 2 | data. `volume prune` without `-a` removes only anonymous volumes |
| `docker system prune --volumes` | 2 | stopped containers, unused networks, dangling images, build cache, and anonymous volumes (named volumes survive) |
| `docker builder prune` | 2 (regenerable) | build cache: slower builds, no data |
| `docker compose down` | outside | the project's containers and networks; volumes survive |
| `docker compose down -v` | 2 | the project's named volumes too: databases go |
| `docker compose rm -v` | 2 | anonymous volumes of the removed containers |
| `docker stop` | outside | in-memory state; the container can be started again |

Before a Tier 2 Docker command, show the list: `docker volume ls`, `docker ps -a --filter ...`,
`docker system df -v`. Back up a volume first (see [compose.md](compose.md)).

## Kubernetes and Helm

| Command | Tier | What is lost |
|---|---|---|
| `kubectl delete pod <pod>` (owned by a Deployment) | 1 on an explicit ask | the pod; its controller replaces it |
| `kubectl delete deployment/statefulset/service ...` | 2 | the workload; a StatefulSet's PVCs survive unless its retention policy deletes them |
| `kubectl delete namespace` | 2 | everything inside it, PVCs (and often their volumes) included |
| `kubectl delete pvc` | 2 | the claim, and the data when the reclaim policy is `Delete` |
| `kubectl apply --prune` | 2 | every labelled resource missing from the manifests you passed |
| `kubectl drain` / `cordon` | outside | pods are evicted and rescheduled; workloads without a PodDisruptionBudget can go fully down |
| `kubectl scale --replicas=0` | outside | serving capacity |
| `helm uninstall` | 2 | every resource in the release; PVCs created from StatefulSet templates stay |
| `helm upgrade --force-replace` (Helm 4; `--force` in 3) | 2 | resources are deleted and recreated: downtime |
| `helm rollback` | 2 | the current release's changes; data migrations are not undone |

Check the current context first (`kubectl config current-context`): the same command against
production is a different tier of mistake. Kubernetes specifics: kubernetes-ops.

## DDEV

| Command | Tier | What is lost |
|---|---|---|
| `ddev delete` | 2 | the project's database and its Docker volumes (a snapshot is taken unless `--omit-snapshot`) |
| `ddev delete images` | 2 (regenerable) | DDEV's images: the next start re-downloads them |
| `ddev import-db`, `ddev snapshot restore` | 2 | the current database, replaced |
| `ddev pull <provider>` | 2 | the local database and upload files, replaced (a no-op files command can empty uploads) |
| `ddev poweroff` / `ddev stop` | outside | running state; all projects with `poweroff` |
| `ddev clean` | 2 | snapshots and images for the named projects |

DDEV specifics: ddev-ops.

## How to ask

Name the targets, the data, and how to undo it. Not "OK to clean up?", but:

> This runs `docker compose down -v` for project `shop`, which deletes volumes `shop_dbdata`
> (Postgres, 1.2 GB) and `shop_uploads`. There's no backup. Back up `shop_dbdata` first, or go ahead?

Approval covers that command and those targets. It is not standing permission for the
next prune.
