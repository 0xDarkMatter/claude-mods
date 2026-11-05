jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      # Without a lockfile entry we would use the npx fallback.
      - run: npx playwright@${PLAYWRIGHT_VERSION} install --with-deps
