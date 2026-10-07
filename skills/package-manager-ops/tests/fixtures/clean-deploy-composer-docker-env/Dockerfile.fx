FROM composer:2 AS vendor
ENV COMPOSER_NO_DEV=1
RUN composer install --optimize-autoloader
