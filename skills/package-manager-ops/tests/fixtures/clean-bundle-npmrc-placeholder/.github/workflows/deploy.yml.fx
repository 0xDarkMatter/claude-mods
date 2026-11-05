name: deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo '//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}' >> .npmrc
      - run: zip -r deploy.zip .
