name: build
on: push
jobs:
  action:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/install
  reusable:
    uses: ./.github/workflows/reusable.yml
