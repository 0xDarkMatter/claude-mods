FROM composer:2 AS vendor
RUN composer update --lock --no-interaction
RUN composer install --no-dev --optimize-autoloader
