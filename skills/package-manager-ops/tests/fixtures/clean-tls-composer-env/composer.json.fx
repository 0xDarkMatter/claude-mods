{
  "name": "fixture/site",
  "type": "project",
  "require": {
    "php": "^8.4",
    "craftcms/cms": "^5.8"
  },
  "require-dev": {
    "yiisoft/yii2-shell": "^2.0.3"
  },
  "repositories": [
    {
      "type": "composer",
      "url": "https://repo.example.com",
      "options": {
        "ssl": {
          "verify_peer": true
        }
      }
    }
  ],
  "config": {
    "platform": {
      "php": "8.4.0"
    },
    "secure-http": true,
    "disable-tls": false,
    "sort-packages": true
  }
}
