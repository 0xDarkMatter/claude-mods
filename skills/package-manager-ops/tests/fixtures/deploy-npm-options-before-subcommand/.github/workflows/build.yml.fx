name: build
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: npm ci --prefix client
      - run: npm --prefix client ci
      - run: npm --silent install
