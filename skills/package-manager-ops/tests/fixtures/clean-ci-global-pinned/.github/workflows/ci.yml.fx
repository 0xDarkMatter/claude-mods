name: ci
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: npm install -g --userconfig ci.npmrc corepack@0.36.0
      - run: npm i -g "pnpm@${PNPM_VERSION}" npm@11.6.2
      - run: npm install --global ./tools/fixture-cli-1.0.0.tgz
      - run: npm ci
