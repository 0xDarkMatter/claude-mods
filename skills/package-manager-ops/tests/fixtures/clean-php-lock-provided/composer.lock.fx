{
  "_readme": [
    "Fixture lock: hand-written, never installed. The root requires a virtual package that a locked package provides."
  ],
  "content-hash": "00000000000000000000000000000000",
  "packages": [
    {
      "name": "craftcms/cms",
      "version": "5.8.10",
      "type": "library"
    },
    {
      "name": "guzzlehttp/guzzle",
      "version": "7.10.0",
      "type": "library",
      "provide": {
        "psr/http-client-implementation": "1.0",
        "psr/http-message-implementation": "1.0"
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
