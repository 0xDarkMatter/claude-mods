FROM php:8.4-fpm
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer update --no-dev --no-interaction
RUN composer global require fixture/tool:1.0.0
