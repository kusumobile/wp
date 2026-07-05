#!/bin/sh
set -eu

mkdir -p /var/www/html/wp-content/mu-plugins

if [ ! -f /var/www/html/wp-load.php ] && [ -d /usr/src/wordpress ]; then
    cp -a /usr/src/wordpress/. /var/www/html/
fi

php_quote() {
    php -r 'echo var_export($argv[1], true);' "$1"
}

secret_value() {
    secret_name="$1"
    secret_file_name="${secret_name}_FILE"

    eval secret_file_path="\${${secret_file_name}:-}"

    if [ -n "$secret_file_path" ] && [ -f "$secret_file_path" ]; then
        cat "$secret_file_path"
        return 0
    fi

    eval secret_value_raw="\${${secret_name}:-}"
    printf '%s' "$secret_value_raw"
}

value_or_file() {
    secret_name="$1"
    secret_file_name="${secret_name}_FILE"

    eval secret_value_raw="\${${secret_name}:-}"
    if [ -n "$secret_value_raw" ]; then
        printf '%s' "$secret_value_raw"
        return 0
    fi

    eval secret_file_path="\${${secret_file_name}:-}"
    if [ -n "$secret_file_path" ] && [ -f "$secret_file_path" ]; then
        cat "$secret_file_path"
        return 0
    fi

    printf '%s' ""
}

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'
}

insert_wp_config_line() {
    config_file="$1"
    config_line="$2"

    if ! grep -Fq "$config_line" "$config_file"; then
        sed -i "/^\/\* That's all, stop editing! /i $(escape_sed_replacement "$config_line")" "$config_file"
    fi
}

wp_pgsql_dropin="/var/www/html/wp-content/plugins/wp-pgsql-database/db.copy"
if [ -f "$wp_pgsql_dropin" ]; then
    cp "$wp_pgsql_dropin" /var/www/html/wp-content/db.php
else
    cat > /var/www/html/wp-content/db.php <<'PHP'
<?php
if ( defined( 'DB_ENGINE' ) && 'pgsql' === DB_ENGINE ) {
    require_once __DIR__ . '/plugins/wp-pgsql-database/includes/driver/class-wp-pgsql-driver-interface.php';
    require_once __DIR__ . '/plugins/wp-pgsql-database/includes/driver/class-wp-pgsql-driver.php';
    require_once __DIR__ . '/plugins/wp-pgsql-database/includes/translator/class-wp-pgsql-lexer.php';
    require_once __DIR__ . '/plugins/wp-pgsql-database/includes/translator/class-wp-pgsql-token.php';
    require_once __DIR__ . '/plugins/wp-pgsql-database/includes/translator/class-wp-pgsql-translator.php';
    require_once __DIR__ . '/plugins/wp-pgsql-database/includes/database/class-wp-pgsql-db.php';
    $wpdb = new \WP_PgSQL_Database\Database\WP_PgSQL_Db( DB_USER, DB_PASSWORD, DB_NAME, DB_HOST );
    $GLOBALS['wpdb'] = $wpdb;
}
PHP
fi

cat > /var/www/html/wp-content/mu-plugins/s3-uploads.php <<'PHP'
<?php
require_once __DIR__ . '/../plugins/s3-uploads/s3-uploads.php';
PHP

cat > /var/www/html/wp-content/mu-plugins/s3-uploads-endpoint.php <<'PHP'
<?php
add_filter( 's3_uploads_s3_client_params', function ( $params ) {
    $endpoint = getenv( 'S3_UPLOADS_ENDPOINT' );

    if ( ! $endpoint ) {
        return $params;
    }

    $params['endpoint'] = rtrim( $endpoint, '/' );
    $params['use_path_style_endpoint'] = filter_var( getenv( 'S3_UPLOADS_PATH_STYLE' ) ?: 'true', FILTER_VALIDATE_BOOLEAN );

    $checksum_mode = getenv( 'S3_UPLOADS_CHECKSUM_MODE' );

    if ( $checksum_mode ) {
        $params['request_checksum_calculation'] = $checksum_mode;
        $params['response_checksum_validation'] = $checksum_mode;
    }

    return $params;
} );
PHP

wp_config_secrets="/var/www/html/wp-content/wp-config-secrets.php"
cat > "$wp_config_secrets" <<'PHP'
<?php
PHP

append_php_define() {
    define_name="$1"
    define_value="$2"

    if [ -n "$define_value" ]; then
        printf "define( '%s', %s );\n" "$define_name" "$(php_quote "$define_value")" >> "$wp_config_secrets"
    fi
}

append_php_define "S3_UPLOADS_BUCKET" "$(secret_value S3_UPLOADS_BUCKET)"
append_php_define "S3_UPLOADS_REGION" "$(secret_value S3_UPLOADS_REGION)"
append_php_define "S3_UPLOADS_KEY" "$(secret_value S3_UPLOADS_KEY)"
append_php_define "S3_UPLOADS_SECRET" "$(secret_value S3_UPLOADS_SECRET)"
append_php_define "S3_UPLOADS_BUCKET_URL" "$(secret_value S3_UPLOADS_BUCKET_URL)" 
append_php_define "S3_UPLOADS_OBJECT_ACL" "$(secret_value S3_UPLOADS_OBJECT_ACL)" 

cat > /usr/local/bin/wordpress-bootstrap.sh <<'SH'
#!/bin/sh
set -eu

secret_value() {
    secret_value_name="$1"
    secret_file_name="${secret_value_name}_FILE"

    eval secret_file_path="\${${secret_file_name}:-}"

    if [ -n "$secret_file_path" ] && [ -f "$secret_file_path" ]; then
        cat "$secret_file_path"
        return 0
    fi

    eval secret_value="\${${secret_value_name}:-}"
    printf '%s' "$secret_value"
}

value_or_file() {
    secret_value_name="$1"
    secret_file_name="${secret_value_name}_FILE"

    eval secret_value="\${${secret_value_name}:-}"
    if [ -n "$secret_value" ]; then
        printf '%s' "$secret_value"
        return 0
    fi

    eval secret_file_path="\${${secret_file_name}:-}"
    if [ -n "$secret_file_path" ] && [ -f "$secret_file_path" ]; then
        cat "$secret_file_path"
        return 0
    fi

    printf '%s' ""
}

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'
}

insert_wp_config_line() {
    config_file="$1"
    config_line="$2"

    if ! grep -Fq "$config_line" "$config_file"; then
        sed -i "/^\/\* That's all, stop editing! /i $(escape_sed_replacement "$config_line")" "$config_file"
    fi
}

cd /var/www/html

if [ -n "${WORDPRESS_DB_PASSWORD_FILE:-}" ] && [ -f "${WORDPRESS_DB_PASSWORD_FILE}" ]; then
    export WORDPRESS_DB_PASSWORD="$(cat "${WORDPRESS_DB_PASSWORD_FILE}")"
fi

if [ -z "${WORDPRESS_DB_PASSWORD:-}" ]; then
    WORDPRESS_DB_PASSWORD="$(value_or_file WORDPRESS_DB_PASSWORD)"
    if [ -n "$WORDPRESS_DB_PASSWORD" ]; then
        export WORDPRESS_DB_PASSWORD
    fi
fi

if [ ! -f /var/www/html/wp-config.php ]; then
    wp config create \
        --allow-root \
        --path=/var/www/html \
        --dbname="${WORDPRESS_DB_NAME:-wordpress}" \
        --dbuser="${WORDPRESS_DB_USER:-wordpress}" \
        --dbpass="${WORDPRESS_DB_PASSWORD:-}" \
        --dbhost="${WORDPRESS_DB_HOST:-localhost}" \
        --skip-check
fi

insert_wp_config_line /var/www/html/wp-config.php "define( 'DB_ENGINE', 'pgsql' );"
insert_wp_config_line /var/www/html/wp-config.php "require_once ABSPATH . 'wp-content/wp-config-secrets.php';"

core_installed=0
if wp core is-installed --allow-root --path=/var/www/html >/dev/null 2>&1; then
    core_installed=1
fi

if [ "$core_installed" -eq 0 ]; then
    admin_password="$(secret_value WORDPRESS_ADMIN_PASSWORD)"

    if [ -z "$admin_password" ]; then
        admin_password="$(value_or_file WORDPRESS_ADMIN_PASSWORD)"
    fi

    if [ -z "$admin_password" ]; then
        admin_password="$(value_or_file WP_ADMIN_PASSWORD)"
    fi

    if [ -z "$admin_password" ]; then
        admin_password="$(value_or_file ADMIN_PASSWORD)"
    fi

    if [ -z "$admin_password" ]; then
        admin_password="admin"
        echo "WORDPRESS_ADMIN_PASSWORD not set; defaulting first-install admin password to 'admin'." >&2
    fi

    wp core install \
        --allow-root \
        --path=/var/www/html \
        --url="${WORDPRESS_URL:-http://localhost:8080}" \
        --title="${WORDPRESS_SITE_TITLE:-WordPress}" \
        --admin_user="${WORDPRESS_ADMIN_USER:-admin}" \
        --admin_password="$admin_password" \
        --admin_email="${WORDPRESS_ADMIN_EMAIL:-admin@example.com}"
fi

wp plugin is-active wp-pgsql-database --allow-root --path=/var/www/html >/dev/null 2>&1 || \
    wp plugin activate wp-pgsql-database --allow-root --path=/var/www/html

wp plugin is-active s3-uploads --allow-root --path=/var/www/html >/dev/null 2>&1 || \
    wp plugin activate s3-uploads --allow-root --path=/var/www/html

if [ "$#" -eq 0 ]; then
    set -- apache2-foreground
fi

exec "$@"
SH

chmod +x /usr/local/bin/wordpress-bootstrap.sh

exec docker-entrypoint.sh sh /usr/local/bin/wordpress-bootstrap.sh "$@"