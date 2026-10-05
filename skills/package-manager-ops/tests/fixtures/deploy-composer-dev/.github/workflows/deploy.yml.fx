name: deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: ramsey/composer-install@v3
        with:
          composer-options: "--prefer-dist --no-interaction --optimize-autoloader"
      - run: npm ci && npm run build
      - run: docker build -t fixture/site .
      - run: docker push registry.example.com/fixture/site:latest
