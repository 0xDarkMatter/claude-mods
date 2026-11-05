name: deploy
on:
  push:
    branches: [production]
env:
  CLIENT_DIR: app/client
jobs:
  deploy:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ${{ env.CLIENT_DIR }}
    steps:
      - uses: actions/checkout@v7
      - run: npm install
      - run: npm run build
      - run: aws s3 sync dist s3://example-bucket
