name: deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo "@acme:registry=https://npm.pkg.github.com" >> .npmrc
      - run: zip -r deploy.zip .
