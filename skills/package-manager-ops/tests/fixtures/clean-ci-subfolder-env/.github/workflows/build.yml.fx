name: build
on:
  push:
    branches: [main]
env:
  NODE_ENV: development
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      THEME_DIR: web/themes/site
    steps:
      - uses: actions/checkout@v7
      - run: npm ci
        working-directory: ${{ github.workspace }}/${{ env.THEME_DIR }}
