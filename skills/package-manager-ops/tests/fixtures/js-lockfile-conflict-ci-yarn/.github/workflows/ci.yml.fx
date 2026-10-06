name: ci
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: yarn install --frozen-lockfile
      - run: yarn build
      - run: npm ci
        working-directory: theme
