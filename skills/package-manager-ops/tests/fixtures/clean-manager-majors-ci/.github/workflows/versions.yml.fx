name: manager versions
on: workflow_dispatch
jobs:
  versions:
    runs-on: ubuntu-latest
    steps:
      - uses: pnpm/action-setup@v4
        with:
          version: 10
      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: 1
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.4'
          tools: composer:v2
      - run: corepack prepare yarn@4.10.0 --activate
