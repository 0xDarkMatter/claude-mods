name: test
on:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: composer install --no-interaction
      - run: vendor/bin/phpunit
      - run: npm install -g corepack@0.36.0
      - run: echo "//npm.example.com/:_authToken=${NPM_TOKEN}" >> ~/.npmrc
      - run: npm ci
      - run: npm run build
      - run: docker build -t fixture/site .
