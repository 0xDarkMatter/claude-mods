{
  "_readme": [
    "Fixture lock: hand-written, never installed. A framework monorepo package replaces the component the root requires."
  ],
  "content-hash": "00000000000000000000000000000000",
  "packages": [
    {
      "name": "craftcms/cms",
      "version": "5.8.10",
      "type": "library"
    },
    {
      "name": "symfony/symfony",
      "version": "v7.3.4",
      "type": "library",
      "replace": {
        "symfony/mailer": "self.version",
        "symfony/mime": "self.version"
      }
    }
  ],
  "packages-dev": [
    {
      "name": "yiisoft/yii2-shell",
      "version": "2.0.6",
      "type": "library"
    }
  ],
  "aliases": [],
  "minimum-stability": "stable",
  "stability-flags": {},
  "prefer-stable": true,
  "prefer-lowest": false,
  "platform": {
    "php": "^8.4"
  },
  "platform-dev": {},
  "platform-overrides": {
    "php": "8.4.0"
  },
  "plugin-api-version": "2.6.0"
}
