name: Deployment
on:
  push:
    branches: [main]
jobs:
  fed:
    name: Frontend Build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v6
        with:
          node-version-file: .nvmrc
      - run: npm ci
      - run: npm run build
      - uses: actions/upload-artifact@v6
        with:
          name: assets
          path: web/dist
  bed:
    name: Backend Test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: composer install --prefer-dist --no-interaction --no-progress
      - run: vendor/bin/ecs check
  tag:
    needs: [fed, bed]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/download-artifact@v7
        with:
          name: assets
          path: web/dist
      - run: |
          git add -f web/dist
          git commit -m "build assets"
          git tag "build-${GITHUB_RUN_NUMBER}"
          git push origin --tags
  deploy:
    needs: tag
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/download-artifact@v7
        with:
          name: assets
          path: web/dist
      - run: composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader
      - run: zip -qr deploy.zip . -x '.git/*'
      - run: aws s3 cp deploy.zip "s3://${DEPLOY_BUCKET}/site/deploy.zip"
      - run: aws deploy create-deployment --application-name site --deployment-group-name production --s3-location "bucket=${DEPLOY_BUCKET},key=site/deploy.zip,bundleType=zip"
