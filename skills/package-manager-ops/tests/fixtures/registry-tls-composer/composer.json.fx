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
      "url": "http://repo.example.com",
      "options": {
        "ssl": {
          "verify_peer": false
        }
      }
    }
  ],
  "config": {
    "platform": {
      "php": "8.4.0"
    },
    "secure-http": false,
    "disable-tls": true,
    "sort-packages": true
  }
}
