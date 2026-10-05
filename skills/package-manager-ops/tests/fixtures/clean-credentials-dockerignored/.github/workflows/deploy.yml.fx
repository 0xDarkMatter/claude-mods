name: deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: echo '${{ secrets.COMPOSER_AUTH_JSON }}' > $GITHUB_WORKSPACE/auth.json
      - run: composer install --no-dev --optimize-autoloader --no-interaction
      - run: docker build -t fixture/site .
      - run: docker push registry.example.com/fixture/site:latest
