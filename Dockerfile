FROM wordpress:php8.0-apache

WORKDIR /var/www/html

# Custom php.ini, now i skip this
# COPY ./custom-php.ini /usr/local/etc/php/conf.d/

# Wordpress config file
COPY ./wp-config.php /var/www/html/wp-config.php

# .htaccess apache
COPY ./.htaccess /var/www/html/.htaccess

# service account gcs
COPY ./gcs-service-account.json /gcs-service-account.json

# pluggin wordpress
COPY ./wp-content /var/www/html/wp-content/

# RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
# && php wp-cli.phar --info \
# && chmod +x wp-cli.phar \
# && mv wp-cli.phar /usr/local/bin/wp

# RUN wp plugin activate --path=/var/www/html --allow-root amazon-s3-and-cloudfront