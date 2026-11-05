name: deploy
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Install theme packages
        working-directory: theme
        run: npm install
      - run: npm run build
        working-directory: ./theme/
