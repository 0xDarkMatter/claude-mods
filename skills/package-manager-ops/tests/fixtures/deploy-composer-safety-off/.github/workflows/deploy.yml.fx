name: unsafe composer deploy
jobs:
  deploy:
    runs-on: ubuntu-latest
    env:
      COMPOSER_NO_AUDIT: 1
    steps:
      - run: composer install --no-dev --no-security-blocking
      - run: composer install --no-dev --ignore-platform-reqs
      - run: aws deploy push --application-name fixture --source .
