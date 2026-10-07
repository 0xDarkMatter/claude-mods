name: build
on: push
jobs:
  action:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/not-present
