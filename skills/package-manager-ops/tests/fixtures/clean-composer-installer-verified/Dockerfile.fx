FROM php:8.4-cli
RUN curl -fsSL https://composer.github.io/installer.sig -o installer.sig \
 && curl -fsSL https://getcomposer.org/installer -o composer-setup.php \
 && echo "$(cat installer.sig)  composer-setup.php" | sha384sum -c - \
 && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
 && rm composer-setup.php installer.sig
