name: composer no-dev env scopes
env:
  COMPOSER_NO_DEV: 1
jobs:
  workflow_env:
    runs-on: ubuntu-latest
    steps:
      - run: composer install --optimize-autoloader
      - run: aws deploy push --application-name fixture --source .
  job_env:
    runs-on: ubuntu-latest
    env:
      COMPOSER_NO_DEV: '1'
    steps:
      - run: composer install --optimize-autoloader
      - run: aws deploy push --application-name fixture --source .
  step_env:
    runs-on: ubuntu-latest
    steps:
      - run: composer install --optimize-autoloader
        env:
          COMPOSER_NO_DEV: true
      - run: aws deploy push --application-name fixture --source .
