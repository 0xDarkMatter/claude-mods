name: deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: "composer install --optimize-autoloader --no-dev"
      - run: |
          composer install \
            --no-dev --optimize-autoloader
      - run: >-
          composer install
          --no-dev --optimize-autoloader
      - run: rsync -a . server:/srv/app
