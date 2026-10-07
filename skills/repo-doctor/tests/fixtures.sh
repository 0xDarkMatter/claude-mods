#!/usr/bin/env bash
# Shared fixture builders for the repo-doctor suites (sourced, never run directly).
#
# make_site DIR builds a PHP CMS site repo: composer + npm manifests, Vite with a
# tracked web/dist, DDEV config/hooks/custom command, a CodeDeploy appspec whose hook
# script holds a secret flag, a CI workflow with a deploy job, PHPUnit, a 900-line
# file, and a synthetic history: modules/a.php+b.php coupled (5 of 5 commits),
# modules/hot.php the hot spot (7), modules/fragile.php hit by 3 fix commits, and
# vite.config.js edits each followed by a web/dist rebuild. Every SENTINEL_* string is
# a planted secret: no tool output may ever contain one.
# Needs: $PY (a working python) and git.

gitq() { git -C "$1" -c core.autocrlf=false "${@:2}"; }
commit() { gitq "$1" add -A; gitq "$1" commit -qm "$2"; }
init_repo() {
    mkdir -p "$1"
    gitq "$1" init -q -b main
    gitq "$1" config user.email t@t.local
    gitq "$1" config user.name t
    gitq "$1" config core.autocrlf false
}
# Windows Python can't open an MSYS path held in an env var; hand it a mixed path.
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

make_site() {
    local S="$1"
    init_repo "$S"
    mkdir -p "$S"/{modules,src,web/dist,scripts,.ddev/commands/web,.github/workflows,tests}
    cat > "$S/composer.json" <<'EOF'
{
  "name": "acme/site",
  "description": "Marketing site fixture",
  "require": { "php": "^8.2", "craftcms/cms": "^5.0" },
  "require-dev": { "phpunit/phpunit": "^10" },
  "scripts": {
    "test": "phpunit",
    "post-install-cmd": ["@php craft clear-caches/all"]
  }
}
EOF
    cat > "$S/package.json" <<'EOF'
{
  "name": "site-frontend",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "deploy": "deploy-tool --token SENTINEL_TOKEN"
  },
  "devDependencies": { "vite": "^5.0.0" }
}
EOF
    echo '{}' > "$S/package-lock.json"
    echo '{}' > "$S/composer.lock"
    cat > "$S/vite.config.js" <<'EOF'
export default {
  build: { outDir: 'web/dist', manifest: true },
}
EOF
    echo "console.log(1)" > "$S/web/dist/app.js"
    cat > "$S/.ddev/config.yaml" <<'EOF'
name: site
type: craftcms
docroot: web
php_version: "8.2"
webserver_type: nginx-fpm
database:
  type: mysql
  version: "8.0"
web_environment:
  - API_TOKEN=SENTINEL_DDEV_VALUE
hooks:
  post-start:
    - exec: php craft migrate/all
EOF
    printf '#!/bin/bash\n## Description: Pull the shared database\n## Usage: sync-db\necho hi\n' \
        > "$S/.ddev/commands/web/sync-db"
    cat > "$S/appspec.yml" <<'EOF'
version: 0.0
os: linux
files:
  - source: /
    destination: /var/www/site
hooks:
  AfterInstall:
    - location: scripts/after_install.sh
      timeout: 300
      runas: root
EOF
    printf '#!/bin/bash\nset -e\ncomposer install --no-dev\nphp craft migrate/all --password=SENTINEL_PW\n' \
        > "$S/scripts/after_install.sh"
    cat > "$S/.github/workflows/ci.yml" <<'EOF'
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - name: Test
      run: composer test
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        run: |
          aws deploy create-deployment --application-name site
EOF
    echo '<phpunit><testsuites><testsuite name="unit"><directory>tests</directory></testsuite></testsuites></phpunit>' \
        > "$S/phpunit.xml.dist"
    echo "APP_KEY=SENTINEL_ENV_SECRET" > "$S/.env"
    echo '{"http-basic": {"x": {"password": "SENTINEL_AUTH"}}}' > "$S/auth.json"
    printf 'DB_PASSWORD=SENTINEL_EXAMPLE_VALUE\nAPP_ENV=dev\n' > "$S/.env.example"
    "$PY" -c "print('\n'.join('<?php // %d' % i for i in range(900)))" > "$S/src/Big.php"
    local f i
    for f in a b hot fragile; do echo "<?php // $f" > "$S/modules/$f.php"; done
    echo "# Site" > "$S/README.md"
    commit "$S" "feat: initial site"
    for i in 1 2 3 4; do
        echo "// pair $i" >> "$S/modules/a.php"; echo "// pair $i" >> "$S/modules/b.php"
        commit "$S" "feat: pair change $i"
    done
    for i in 1 2 3 4 5 6; do echo "// hot $i" >> "$S/modules/hot.php"; commit "$S" "feat: hot $i"; done
    for i in 1 2 3; do
        echo "// fix $i" >> "$S/modules/fragile.php"
        commit "$S" "fix: fragile bug $i api_key=SENTINEL_SUBJECT"
    done
    for i in 1 2 3; do
        echo "// tweak $i" >> "$S/vite.config.js"; commit "$S" "chore: tweak vite $i"
        echo "console.log($i)" >> "$S/web/dist/app.js"; commit "$S" "build: rebuild $i"
    done
}

make_monorepo() {
    local S="$1"
    init_repo "$S"
    mkdir -p "$S"/{packages/engine/src,packages/engine/tests,packages/engine/internal,packages/ui/src,apps/web/src,assets,tools,.ruler,docs/agents,.cursor}
    cat > "$S/package.json" <<'EOF'
{
  "name": "monorepo-fixture",
  "private": true,
  "workspaces": ["packages/*", "apps/*"],
  "scripts": { "check": "npm -w @fixture/engine test" }
}
EOF
    cat > "$S/packages/engine/package.json" <<'EOF'
{
  "name": "@fixture/engine",
  "main": "src/index.ts",
  "bin": { "engine": "src/cli.ts" },
  "exports": { ".": "./src/index.ts", "./parse": "./src/parse.ts" },
  "scripts": { "test": "bash tests/run.sh", "check:deps": "depcruise src" },
  "devDependencies": { "dependency-cruiser": "1.0.0" }
}
EOF
    cat > "$S/packages/engine/.dependency-cruiser.cjs" <<'EOF'
module.exports = {
  forbidden: [{ name: 'no-ui', from: { path: '^src' }, to: { path: 'packages/ui' } }],
  baseline: '.dependency-cruiser-baseline.json',
}
EOF
    cat > "$S/packages/engine/.dependency-cruiser-baseline.json" <<'EOF'
[
  { "from": "src/a.ts", "to": "../ui/a.ts" },
  { "from": "src/b.ts", "to": "../ui/b.ts" },
  { "from": "src/c.ts", "to": "../ui/c.ts" }
]
EOF
    printf '#!/bin/bash\nset -eu\necho engine-tests\n' > "$S/packages/engine/tests/run.sh"
    printf 'export const engine = true\n' > "$S/packages/engine/src/index.ts"
    printf 'export const cli = true\n' > "$S/packages/engine/src/cli.ts"
    printf 'export const parse = true\n' > "$S/packages/engine/src/parse.ts"
    printf 'package internal\n' > "$S/packages/engine/internal/guard.go"
    local i
    for i in $(seq -w 1 14); do
        printf 'export const a%s = true\n' "$i" > "$S/packages/engine/src/a$i.ts"
    done
    cat > "$S/packages/ui/package.json" <<'EOF'
{ "name": "@fixture/ui", "main": "src/index.ts" }
EOF
    printf 'export const ui = true\n' > "$S/packages/ui/src/index.ts"
    for i in $(seq -w 1 14); do
        printf 'export const u%s = true\n' "$i" > "$S/packages/ui/src/u$i.ts"
    done
    cat > "$S/apps/web/package.json" <<'EOF'
{ "name": "@fixture/web", "main": "src/index.ts" }
EOF
    printf 'FROM scratch\n' > "$S/apps/web/Dockerfile"
    printf 'export const web = true\n' > "$S/apps/web/src/index.ts"
    for i in $(seq -w 1 14); do
        printf 'export const w%s = true\n' "$i" > "$S/apps/web/src/w$i.ts"
    done
    for i in $(seq -w 1 300); do printf 'asset %s\n' "$i" > "$S/assets/a$i.txt"; done
    local tool
    for tool in $(seq -w 1 9); do
        mkdir -p "$S/tools/t$tool/src"
        printf '{ "name": "@fixture/tool-%s" }\n' "$tool" > "$S/tools/t$tool/package.json"
        printf 'export const tool = true\n' > "$S/tools/t$tool/src/index.ts"
    done
    cat > "$S/AGENTS.md" <<'EOF'
<!-- Generated by ruler. Edit .ruler/ sources. -->
# Fixture instructions

@docs/agents/extra.md

## Landmines

- `packages/engine/src/fragile.ts` must keep its compatibility shim.
EOF
    printf '# Extra instructions\n' > "$S/docs/agents/extra.md"
    printf '# Source rules\n' > "$S/.ruler/rules.md"
    printf '# Gemini instructions\n' > "$S/GEMINI.md"
    printf 'alwaysApply: true\n' > "$S/.cursor/rules.mdc"
    commit "$S" "feat: initial monorepo"
    for i in 1 2 3; do
        printf '// pair %s\n' "$i" >> "$S/packages/engine/src/a01.ts"
        printf '// pair %s\n' "$i" >> "$S/packages/engine/src/a02.ts"
        commit "$S" "feat: couple engine modules $i"
    done
    for i in 1 2 3; do
        printf '// fix %s\n' "$i" >> "$S/packages/engine/src/parse.ts"
        commit "$S" "fix: engine parser $i"
    done
}
