FROM php:8.4-fpm
COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer
