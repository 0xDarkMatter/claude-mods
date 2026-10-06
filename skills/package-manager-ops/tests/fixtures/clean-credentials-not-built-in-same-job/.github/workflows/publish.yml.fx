name: publish
on:
  release:
    types: [published]
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: echo "//npm.example.com/:_authToken=${NPM_TOKEN}" > .npmrc
      - run: npm publish
