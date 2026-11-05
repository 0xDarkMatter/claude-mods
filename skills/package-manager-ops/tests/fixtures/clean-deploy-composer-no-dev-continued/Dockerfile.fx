FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install \
    --no-dev --optimize-autoloader --no-interaction
RUN ["composer", "dump-autoload", "--no-dev", "--classmap-authoritative"]
