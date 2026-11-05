name: install
runs:
  using: composite
  steps:
    - shell: bash
      run: npm install
