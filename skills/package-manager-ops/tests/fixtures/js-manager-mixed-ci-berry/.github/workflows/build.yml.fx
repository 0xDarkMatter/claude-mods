name: build
on:
  pull_request:
jobs:
  theme:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: yarn install
        working-directory: theme
