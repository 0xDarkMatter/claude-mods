name: reusable
on: workflow_call
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: npm ci
