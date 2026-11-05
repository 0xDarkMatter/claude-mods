name: ci
on:
  pull_request:
jobs:
  matrix:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node: [22, 24]
        php: ['8.3', '8.4']
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v5
        with:
          node-version: ${{ matrix.node }}
      - uses: shivammathur/setup-php@v2
        with:
          php-version: ${{ matrix.php }}
  pinned:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v5
        with:
          node-version: 24.x
      - uses: shivammathur/setup-php@v2
        with:
          php-version: "8.4"
      - uses: actions/setup-node@v5
        with:
          node-version: lts/*
      - uses: actions/setup-node@v5
        with:
          node-version-file: .nvmrc
      - name: An unrelated action with look-alike inputs
        uses: example/legacy-lint@v1
        with:
          php-version: '5.6'
          node-version: '8'
      - run: npm ci
