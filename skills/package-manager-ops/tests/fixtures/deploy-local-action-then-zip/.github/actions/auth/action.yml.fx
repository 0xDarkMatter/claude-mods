runs:
  using: composite
  steps:
    - run: echo "//registry.invalid/:_authToken=${NPM_TOKEN}" > .npmrc
      shell: bash
