name: Deployment
on:
    push:
        branches: [main]
jobs:
    bed:
        name: Backend Test
        runs-on: ubuntu-latest
        steps:
            - uses: actions/checkout@v7
            - run: composer install --prefer-dist --no-interaction --no-progress
            - run: vendor/bin/phpstan analyse
    deploy:
        needs: bed
        runs-on: ubuntu-latest
        steps:
            - uses: actions/checkout@v7
            - run: npm ci && npm run build
            - run: composer install --prefer-dist --no-interaction --optimize-autoloader
            - run: zip -qr release.zip . -x '.git/*' 'node_modules/*'
            - run: aws s3 cp release.zip s3://releases.example.com/site/release.zip
