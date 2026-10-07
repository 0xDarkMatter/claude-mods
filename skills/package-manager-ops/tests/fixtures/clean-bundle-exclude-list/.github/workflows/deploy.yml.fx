name: deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo "//registry.invalid/:_authToken=${NPM_TOKEN}" > .npmrc
      - run: zip -r deploy.zip . -x@.deployignore
