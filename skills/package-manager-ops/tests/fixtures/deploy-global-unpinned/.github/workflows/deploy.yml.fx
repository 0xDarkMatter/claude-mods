name: deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: npm install -g gulp-cli
      - run: npm i --global firebase-tools@^13.0.0 ripgrep
      - run: npm ci
      - run: firebase deploy
