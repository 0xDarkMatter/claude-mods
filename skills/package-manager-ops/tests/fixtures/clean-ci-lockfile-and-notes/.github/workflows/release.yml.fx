name: release
on:
  push:
    branches: [main]
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: npm install --package-lock-only
      - uses: softprops/action-gh-release@v2
        with:
          body: |
            Install with:
            composer require fixture/site:^1.0
            npm install
      - run: docker build -t fixture/site .
      - run: docker push registry.example.com/fixture/site:latest
