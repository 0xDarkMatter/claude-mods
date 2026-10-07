{
  "name": "fixture/site",
  "type": "project",
  "minimum-stability": "dev",
  "prefer-stable": false,
  "repositories": [
    {"type": "vcs", "url": "https://example.invalid/fixture/repo"},
    {"type": "path", "url": "../fixture-package"},
    {"type": "artifact", "url": "artifacts/"}
  ],
  "require": {"php": "^8.4", "craftcms/cms": "^5.8"},
  "require-dev": {"yiisoft/yii2-shell": "dev-main"},
  "config": {"platform": {"php": "8.4.0"}}
}
