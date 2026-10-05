FROM php:8.4-fpm
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer update --no-dev --no-interaction
