name: test
on:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '7.1'
          tools: composer:v2
      - run: composer install
      - run: vendor/bin/phpunit
