name: deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo '//registry.invalid/:_authToken=$NODE_AUTH_TOKEN' | envsubst > .npmrc
      - run: zip -r deploy.zip .
