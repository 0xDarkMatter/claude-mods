name: build
on:
  pull_request:
jobs:
  inline:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: cd theme && npm ci
  block:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: |
          cd theme
          npm ci
          npm run build
  workspace:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: cd "$GITHUB_WORKSPACE/theme" && npm ci
