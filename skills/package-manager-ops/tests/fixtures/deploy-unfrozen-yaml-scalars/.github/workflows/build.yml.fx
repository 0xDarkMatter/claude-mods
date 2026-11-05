name: build
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: "npm install"
      - run: >-
          npm
          install --no-audit
      - run: |
          npm ci
          echo "npm install --no-audit"
          echo then run npm install yourself
          printf 'npm install\n' > NOTES.txt
