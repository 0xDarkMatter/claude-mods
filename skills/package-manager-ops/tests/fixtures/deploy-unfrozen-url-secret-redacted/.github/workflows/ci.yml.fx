name: ci
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: yarn --registry=https://ci-user:FIXTURE-URL-SECRET@npm.example.com/ install
