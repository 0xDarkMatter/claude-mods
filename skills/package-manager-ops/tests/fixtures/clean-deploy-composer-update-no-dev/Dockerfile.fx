FROM composer:2 AS vendor
RUN composer install --update-no-dev --optimize-autoloader
