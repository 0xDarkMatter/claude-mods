name: build
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: npm ci --frozen-lockfile
      - run: npm install --immutable
      - run: npm run build
