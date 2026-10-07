name: fixture
nodejs_version: "24"
php_version: "8.4"
hooks:
  post-start:
    - exec: npm install
