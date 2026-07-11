FROM wordpress:6.8.3-php8.3-apache

USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libpq-dev \
        unzip; \
    docker-php-ext-install pdo_pgsql pgsql; \
    rm -rf /var/lib/apt/lists/*

ARG COMPOSER_VERSION=2.7.9

RUN set -eux; \
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php; \
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --version=${COMPOSER_VERSION}; \
    rm -f /tmp/composer-setup.php

RUN set -eux; \
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp; \
    chmod +x /usr/local/bin/wp

ARG PLUGINS_CACHE_BUST=1

RUN set -eux; \
    curl -fsSL https://github.com/mralaminahamed/wp-pgsql-database/archive/refs/heads/trunk.zip -o /tmp/wp-pgsql-database.zip; \
    unzip /tmp/wp-pgsql-database.zip -d /usr/src/wordpress/wp-content/plugins; \
    mv /usr/src/wordpress/wp-content/plugins/wp-pgsql-database-trunk /usr/src/wordpress/wp-content/plugins/wp-pgsql-database; \
    rm -f /tmp/wp-pgsql-database.zip; \
    if [ -f /usr/src/wordpress/wp-content/plugins/wp-pgsql-database/composer.json ]; then composer install --no-dev --prefer-dist --no-interaction --no-progress --working-dir=/usr/src/wordpress/wp-content/plugins/wp-pgsql-database; fi; \
    curl -fsSL https://github.com/humanmade/S3-Uploads/archive/refs/heads/master.zip -o /tmp/s3-uploads.zip; \
    unzip /tmp/s3-uploads.zip -d /usr/src/wordpress/wp-content/plugins; \
    mv /usr/src/wordpress/wp-content/plugins/S3-Uploads-master /usr/src/wordpress/wp-content/plugins/s3-uploads; \
    rm -f /tmp/s3-uploads.zip; \
    if [ -f /usr/src/wordpress/wp-content/plugins/s3-uploads/composer.json ]; then composer install --no-dev --prefer-dist --no-interaction --no-progress --working-dir=/usr/src/wordpress/wp-content/plugins/s3-uploads; fi; \
    mkdir -p /var/www/html/wp-content/mu-plugins; \
    chown -R www-data:www-data /var/www/html/wp-content

# Patch PostgreSQL translator: fix ON CONFLICT target + VALUES(col) → EXCLUDED.col
COPY docker-entrypoint-custom.sh /usr/local/bin/docker-entrypoint-custom.sh

RUN sed -i 's/\r$//' /usr/local/bin/docker-entrypoint-custom.sh \
    && chmod +x /usr/local/bin/docker-entrypoint-custom.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-custom.sh"]
CMD ["apache2-foreground"]
