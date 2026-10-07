name: platform compatibility test
jobs:
  test:
    runs-on: ubuntu-latest
    env:
      COMPOSER_NO_AUDIT: 1
    steps:
      - run: composer install --ignore-platform-reqs
      - run: vendor/bin/phpunit
