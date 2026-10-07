name: build
on: push
jobs:
  action:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/install
  reusable:
    uses: ./.github/workflows/reusable.yml
