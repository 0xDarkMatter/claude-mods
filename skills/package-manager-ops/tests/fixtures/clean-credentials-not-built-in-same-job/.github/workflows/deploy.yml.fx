name: deploy
on:
  push:
    branches: [main]
jobs:
  auth:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: echo "//npm.example.com/:_authToken=${NPM_TOKEN}" > .npmrc
      - run: npm ci
  image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: docker build -t fixture/site .
