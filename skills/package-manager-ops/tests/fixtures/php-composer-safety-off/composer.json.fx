{
  "name": "fixture/site",
  "type": "project",
  "require": {"php": "^8.4", "craftcms/cms": "^5.8"},
  "require-dev": {"yiisoft/yii2-shell": "^2.0.3"},
  "config": {
    "platform": {"php": "8.4.0"},
    "allow-plugins": true,
    "secure-http": false,
    "disable-tls": true,
    "audit": {"block-insecure": false, "abandoned": "ignore"}
  }
}
