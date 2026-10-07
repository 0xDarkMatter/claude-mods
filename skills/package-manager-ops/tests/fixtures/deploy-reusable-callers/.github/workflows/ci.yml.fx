name: ci
on: push
jobs:
  build:
    uses: ./.github/workflows/reusable.yml
  lint:
    uses: ./.github/workflows/reusable.yml
