FROM php:8.4-fpm
COPY --from=composer:2.2 /usr/bin/composer /usr/bin/composer
