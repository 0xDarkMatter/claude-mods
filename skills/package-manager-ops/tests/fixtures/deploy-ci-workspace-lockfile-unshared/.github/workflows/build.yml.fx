name: build
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: pnpm/action-setup@v4
      - run: pnpm install --frozen-lockfile
        working-directory: apps/web
