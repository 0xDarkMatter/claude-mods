name: deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.4'
          tools: composer:v1
      - run: composer install --no-dev --optimize-autoloader --no-interaction
      - run: docker build -t fixture/site .
      - run: docker push registry.example.com/fixture/site:latest
