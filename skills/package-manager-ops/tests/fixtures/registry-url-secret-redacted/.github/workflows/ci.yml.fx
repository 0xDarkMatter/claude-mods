name: ci
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: npm ci --registry=https://ci-user:FIXTURE-URL-SECRET@npm.example.com/
      - run: npm install -g fixture-tool@https://ci-user:FIXTURE-URL-SECRET@npm.example.com/fixture-tool.tgz
      - run: npm run build
