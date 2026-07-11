#!/bin/sh
set -eu

mkdir -p /var/www/html/wp-content/mu-plugins
mkdir -p /var/www/html/wp-content/plugins

if [ ! -f /var/www/html/wp-load.php ] && [ -d /usr/src/wordpress ]; then
    cp -a /usr/src/wordpress/. /var/www/html/
fi

# Keep custom plugins available when wp-content is a named volume.
for plugin_dir in wp-pgsql-database s3-uploads; do
    if [ ! -d "/var/www/html/wp-content/plugins/${plugin_dir}" ] && [ -d "/usr/src/wordpress/wp-content/plugins/${plugin_dir}" ]; then
        cp -a "/usr/src/wordpress/wp-content/plugins/${plugin_dir}" "/var/www/html/wp-content/plugins/${plugin_dir}"
    fi
done

# Ensure S3 Uploads dependencies exist in persisted volumes from earlier runs.
if [ -d /usr/src/wordpress/wp-content/plugins/s3-uploads/vendor ] && [ ! -d /var/www/html/wp-content/plugins/s3-uploads/vendor ]; then
    mkdir -p /var/www/html/wp-content/plugins/s3-uploads
    cp -a /usr/src/wordpress/wp-content/plugins/s3-uploads/vendor /var/www/html/wp-content/plugins/s3-uploads/vendor
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

set_from_first_non_empty_env() {
    target_var="$1"
    shift

    for var_name in "$@"; do
        eval var_value="\${${var_name}:-}"
        if [ -n "$var_value" ]; then
            eval "$target_var=\$var_value"
            return 0
        fi
    done

    return 1
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

cat > /var/www/html/wp-content/db.php <<'PHP'
<?php
// Always initialize the PostgreSQL drop-in so manual setup-config.php
// generated wp-config.php files still use PostgreSQL without extra constants.
if ( ! defined( 'DB_HOST' ) || ! defined( 'DB_USER' ) || ! defined( 'DB_PASSWORD' ) || ! defined( 'DB_NAME' ) ) {
    return;
}

require_once __DIR__ . '/plugins/wp-pgsql-database/includes/driver/class-wp-pgsql-driver-interface.php';
require_once __DIR__ . '/plugins/wp-pgsql-database/includes/driver/class-wp-pgsql-driver.php';
require_once __DIR__ . '/plugins/wp-pgsql-database/includes/translator/class-wp-pgsql-lexer.php';
require_once __DIR__ . '/plugins/wp-pgsql-database/includes/translator/class-wp-pgsql-token.php';
require_once __DIR__ . '/plugins/wp-pgsql-database/includes/translator/class-wp-pgsql-translator.php';
require_once __DIR__ . '/plugins/wp-pgsql-database/includes/database/class-wp-pgsql-db.php';
require_once __DIR__ . '/plugins/wp-pgsql-database/includes/schema/class-wp-pgsql-schema-mapper.php';

/**
 * Extend the base translator to fix ON CONFLICT syntax for PostgreSQL.
 */
class WP_PgSQL_Translator_Fixed extends \WP_PgSQL_Database\Translator\WP_PgSQL_Translator {
    public function translate( string $sql ): string {
        $translated = parent::translate( $sql );

        // Fix VALUES(col) → EXCLUDED."col" in ON CONFLICT DO UPDATE clauses.
        if ( stripos( $translated, 'ON CONFLICT DO UPDATE SET' ) !== false ) {
            $translated = preg_replace_callback(
                '/\bON\s+CONFLICT\s+DO\s+UPDATE\s+SET\s+(.+)/is',
                static function ( $m ) use ( $sql ) {
                    $assignments = preg_replace(
                        '/\bVALUES\s*\(\s*["`]?([a-zA-Z0-9_]+)["`]?\s*\)/i',
                        'EXCLUDED."$1"',
                        $m[1]
                    );

                    $target = '';
                    if ( preg_match( '/\(([^)]*)\)\s*VALUES/is', $sql, $cm ) ) {
                        $cols = array_filter( array_map(
                            static function ( $c ) { return trim( $c, " \t\n\r\0\x0B`\"" ); },
                            explode( ',', $cm[1] )
                        ) );
                        $cols = array_values( $cols );
                        if ( in_array( 'option_name', $cols, true ) ) {
                            $target = ' ("option_name")';
                        } elseif ( in_array( 'object_id', $cols, true ) && in_array( 'term_taxonomy_id', $cols, true ) ) {
                            $target = ' ("object_id","term_taxonomy_id")';
                        } elseif ( ! empty( $cols ) ) {
                            $target = ' ("' . $cols[0] . '")';
                        }
                    }

                    return 'ON CONFLICT' . $target . ' DO UPDATE SET ' . $assignments;
                },
                $translated
            );
        }

        return $translated;
    }
}

/**
 * Extend wpdb with PostgreSQL-compatible methods.
 */
class WP_PgSQL_Db_Compat extends \WP_PgSQL_Database\Database\WP_PgSQL_Db {
    public function __construct( $u, $p, $n, $h ) {
        parent::__construct( $u, $p, $n, $h );
        // Swap in our fixed translator via reflection so no base-class changes needed.
        $ref   = new ReflectionClass( \WP_PgSQL_Database\Database\WP_PgSQL_Db::class );
        $prop  = $ref->getProperty( 'translator' );
        $prop->setAccessible( true );
        $prop->setValue( $this, new WP_PgSQL_Translator_Fixed( new \WP_PgSQL_Database\Translator\WP_PgSQL_Lexer() ) );

        // Mark as connected for wpdb internals that expect this state.
        $this->has_connected = true;
    }

    /**
     * Skip mysqli connection logic; PostgreSQL driver is already connected.
     */
    public function db_connect( $allow_bail = true ): bool {
        return (bool) $this->ready;
    }

    /**
     * Skip mysqli health checks; rely on PostgreSQL driver readiness.
     */
    public function check_connection( $allow_bail = true ): bool {
        return (bool) $this->ready;
    }

    /**
     * WordPress expects user objects with uppercase ID; PostgreSQL returns lowercase id.
     */
    private function normalize_result_ids(): void {
        if ( empty( $this->last_result ) || ! is_array( $this->last_result ) ) {
            return;
        }

        foreach ( $this->last_result as $row ) {
            if ( ! is_object( $row ) ) {
                continue;
            }

            $vars = get_object_vars( $row );
            if ( array_key_exists( 'id', $vars ) && ! array_key_exists( 'ID', $vars ) ) {
                $row->ID = $vars['id'];
            }
        }
    }

    /**
     * Normalize mapped DDL that still uses MySQL-specific syntax.
     */
    private function normalize_ddl_sql( string $query ): string {
        $query = preg_replace( '/\bBIGINT\s*\(\s*\d+\s*\)/i', 'BIGINT', $query );
        $query = preg_replace( '/\bINTEGER\s*\(\s*\d+\s*\)/i', 'INTEGER', $query );
        $query = preg_replace( '/\bUNIQUE\s+KEY\s+\w+\s*\(([^)]+)\)/i', 'UNIQUE ($1)', $query );
        $query = str_ireplace( "'0000-00-00 00:00:00'", "'1970-01-01 00:00:00'", $query );
        $query = preg_replace( '/\)\)\s*\n\s*\)/', ")\n)", $query );

        return $query;
    }

    /**
     * Avoid mysqli-specific fatal paths while running on PostgreSQL.
     */
    public function print_error( $str = '' ) {
        if ( empty( $str ) && ! empty( $this->last_error ) ) {
            $str = $this->last_error;
        }

        if ( ! empty( $str ) ) {
            error_log( 'WordPress database error: ' . $str );
        }

        return false;
    }

    /**
     * PostgreSQL folds unquoted identifiers to lowercase.
     * Normalize quoted identifiers from translated MySQL SQL (e.g. "ID") to lowercase.
     */
    private function normalize_identifier_case( string $query ): string {
        return preg_replace_callback(
            '/"([A-Za-z_][A-Za-z0-9_]*)"/',
            static function ( array $m ): string {
                return '"' . strtolower( $m[1] ) . '"';
            },
            $query
        );
    }

    /**
     * Enable verbose SQL tracing only when explicitly requested.
     */
    private function is_debug_enabled(): bool {
        static $enabled = null;

        if ( $enabled !== null ) {
            return $enabled;
        }

        $raw = getenv( 'WP_PGSQL_DEBUG' );
        if ( $raw === false || $raw === '' ) {
            $enabled = false;
            return $enabled;
        }

        $enabled = in_array( strtolower( (string) $raw ), array( '1', 'true', 'yes', 'on' ), true );
        return $enabled;
    }

    /**
     * Intercept queries: run DDL through schema mapper and fix MySQL multi-table DELETE.
     */
    public function query( $query ) {
        $is_ddl = false;
        $original_query = $query;

        $query = $this->normalize_identifier_case( $query );

        // Translate DESCRIBE table probes to PostgreSQL metadata queries.
        if ( preg_match( '/^\s*DESCRIBE\s+[`"]?([a-zA-Z0-9_]+)[`"]?\s*;?\s*$/i', $query, $m ) ) {
            $table = $m[1];
            $query = "SELECT column_name AS Field, data_type AS Type, is_nullable AS Null, column_default AS \"Default\"\n"
                . "FROM information_schema.columns\n"
                . "WHERE table_schema = 'public'\n"
                . "  AND table_name = '" . $table . "'\n"
                . "ORDER BY ordinal_position";
        }

        // Route CREATE TABLE / ALTER TABLE through schema mapper.
        if ( preg_match( '/^\s*(CREATE|ALTER)\s+TABLE\b/i', $query ) ) {
            $is_ddl = true;
            $mapper = new \WP_PgSQL_Database\Schema\WP_PgSQL_Schema_Mapper();
            $query  = $mapper->rewrite( $query );
            $query  = $this->normalize_ddl_sql( $query );
        }
        // Strip MySQL multi-table DELETE syntax (not supported in PostgreSQL).
        if ( preg_match( '/^\s*DELETE\s+\w+\s*,/i', $query ) ) {
            return false;
        }

        $result = parent::query( $query );

        // During fresh install checks, WordPress probes wp_options before tables exist.
        // Treat missing wp_options as "not installed yet" instead of hard DB failure.
        if (
            $result === false
            && preg_match( '/\bFROM\s+wp_options\b/i', $query )
            && ! empty( $this->last_error )
            && stripos( $this->last_error, 'relation "wp_options" does not exist' ) !== false
        ) {
            $this->last_error = '';
        }

        if ( $result !== false ) {
            $this->normalize_result_ids();
        }

        if ( $this->is_debug_enabled() && ( $is_ddl || $result === false ) ) {
            $line = "\n[" . gmdate( 'c' ) . "] result=" . ( $result === false ? 'false' : 'ok' ) . "\n";
            if ( $is_ddl ) {
                $line .= "ORIGINAL:\n" . $original_query . "\n\nREWRITTEN:\n" . $query . "\n";
            } else {
                $line .= "QUERY:\n" . $query . "\n";
            }
            if ( ! empty( $this->last_error ) ) {
                $line .= "ERROR:\n" . $this->last_error . "\n";
            }
            @file_put_contents( '/tmp/wp-pgsql-query.log', $line . "\n", FILE_APPEND );
        }

        return $result;
    }

    public function db_version(): string {
        $raw = parent::db_version();
        if ( preg_match( '/(\d+(?:\.\d+){1,2})/', $raw, $m ) ) {
            return $m[1];
        }

        // Return a high-enough numeric fallback for core version comparisons.
        return '8.0.0';
    }

    public function db_server_info(): string {
        return 'PostgreSQL ' . $this->db_version();
    }
}

$wpdb = new WP_PgSQL_Db_Compat( DB_USER, DB_PASSWORD, DB_NAME, DB_HOST );
$GLOBALS['wpdb'] = $wpdb;
PHP

cat > /var/www/html/wp-content/mu-plugins/s3-uploads.php <<'PHP'
<?php
if ( file_exists( __DIR__ . '/../plugins/s3-uploads/vendor/autoload.php' ) ) {
    require_once __DIR__ . '/../plugins/s3-uploads/vendor/autoload.php';
}
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

cat >> "$wp_config_secrets" <<'PHP'
if ( ! defined( 'WP_INSTALLING' ) ) {
    $is_install_request = isset( $_SERVER['REQUEST_URI'] ) && strpos( $_SERVER['REQUEST_URI'], '/wp-admin/install.php' ) !== false;

    if ( $is_install_request ) {
        define( 'WP_INSTALLING', true );
    }
}
PHP

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

set_from_first_non_empty_env() {
    target_var="$1"
    shift

    for var_name in "$@"; do
        eval var_value="\${${var_name}:-}"
        if [ -n "$var_value" ]; then
            eval "$target_var=\$var_value"
            return 0
        fi
    done

    return 1
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

if [ -z "${WORDPRESS_DB_HOST:-}" ]; then
    set_from_first_non_empty_env WORDPRESS_DB_HOST DATABASE_HOST DB_HOST POSTGRES_HOST PGHOST || true
fi

if [ -z "${WORDPRESS_DB_PORT:-}" ]; then
    set_from_first_non_empty_env WORDPRESS_DB_PORT DATABASE_PORT DB_PORT POSTGRES_PORT PGPORT || true
fi

if [ -z "${WORDPRESS_DB_NAME:-}" ]; then
    set_from_first_non_empty_env WORDPRESS_DB_NAME DATABASE_NAME DB_NAME POSTGRES_DB POSTGRES_DATABASE PGDATABASE || true
fi

if [ -z "${WORDPRESS_DB_USER:-}" ]; then
    set_from_first_non_empty_env WORDPRESS_DB_USER DATABASE_USERNAME DATABASE_USER DB_USERNAME DB_USER POSTGRES_USER PGUSER || true
fi

if [ -z "${WORDPRESS_DB_PASSWORD:-}" ]; then
    set_from_first_non_empty_env WORDPRESS_DB_PASSWORD DATABASE_PASSWORD DB_PASSWORD POSTGRES_PASSWORD PGPASSWORD || true
fi

db_url=""
set_from_first_non_empty_env db_url DATABASE_URL DB_URL POSTGRES_URL POSTGRESQL_URL PG_URL DATABASE_CONNECTION_STRING || true
if [ -n "$db_url" ]; then
    if [ -z "${WORDPRESS_DB_HOST:-}" ]; then
        WORDPRESS_DB_HOST="$(DB_URL_VALUE="$db_url" php -r '$u=parse_url(getenv("DB_URL_VALUE")); echo isset($u["host"])?$u["host"]:"";')"
    fi
    if [ -z "${WORDPRESS_DB_PORT:-}" ]; then
        WORDPRESS_DB_PORT="$(DB_URL_VALUE="$db_url" php -r '$u=parse_url(getenv("DB_URL_VALUE")); echo isset($u["port"])?$u["port"]:"";')"
    fi
    if [ -z "${WORDPRESS_DB_NAME:-}" ]; then
        WORDPRESS_DB_NAME="$(DB_URL_VALUE="$db_url" php -r '$u=parse_url(getenv("DB_URL_VALUE")); echo isset($u["path"])?ltrim($u["path"],"/"):"";')"
    fi
    if [ -z "${WORDPRESS_DB_USER:-}" ]; then
        WORDPRESS_DB_USER="$(DB_URL_VALUE="$db_url" php -r '$u=parse_url(getenv("DB_URL_VALUE")); echo isset($u["user"])?rawurldecode($u["user"]):"";')"
    fi
    if [ -z "${WORDPRESS_DB_PASSWORD:-}" ]; then
        WORDPRESS_DB_PASSWORD="$(DB_URL_VALUE="$db_url" php -r '$u=parse_url(getenv("DB_URL_VALUE")); echo isset($u["pass"])?rawurldecode($u["pass"]):"";')"
    fi
fi

if [ -n "${WORDPRESS_DB_HOST:-}" ] && [ -n "${WORDPRESS_DB_PORT:-}" ]; then
    case "$WORDPRESS_DB_HOST" in
        *:*) ;;
        *) WORDPRESS_DB_HOST="${WORDPRESS_DB_HOST}:${WORDPRESS_DB_PORT}" ;;
    esac
fi

export WORDPRESS_DB_HOST WORDPRESS_DB_NAME WORDPRESS_DB_USER WORDPRESS_DB_PASSWORD

for password_file_var in WORDPRESS_DB_PASSWORD_FILE DATABASE_PASSWORD_FILE DB_PASSWORD_FILE POSTGRES_PASSWORD_FILE PGPASSWORD_FILE; do
    eval password_file_path="\${${password_file_var}:-}"
    if [ -n "$password_file_path" ] && [ -f "$password_file_path" ]; then
        export WORDPRESS_DB_PASSWORD="$(cat "$password_file_path")"
        break
    fi
done

if [ -z "${WORDPRESS_DB_PASSWORD:-}" ]; then
    WORDPRESS_DB_PASSWORD="$(value_or_file WORDPRESS_DB_PASSWORD)"
    if [ -z "$WORDPRESS_DB_PASSWORD" ]; then
        WORDPRESS_DB_PASSWORD="$(value_or_file DATABASE_PASSWORD)"
    fi
    if [ -z "$WORDPRESS_DB_PASSWORD" ]; then
        WORDPRESS_DB_PASSWORD="$(value_or_file DB_PASSWORD)"
    fi
    if [ -z "$WORDPRESS_DB_PASSWORD" ]; then
        WORDPRESS_DB_PASSWORD="$(value_or_file POSTGRES_PASSWORD)"
    fi
    if [ -z "$WORDPRESS_DB_PASSWORD" ]; then
        WORDPRESS_DB_PASSWORD="$(value_or_file PGPASSWORD)"
    fi
    if [ -n "$WORDPRESS_DB_PASSWORD" ]; then
        export WORDPRESS_DB_PASSWORD
    fi
fi

db_ready=1
if [ -z "${WORDPRESS_DB_HOST:-}" ] || [ -z "${WORDPRESS_DB_NAME:-}" ] || [ -z "${WORDPRESS_DB_USER:-}" ] || [ -z "${WORDPRESS_DB_PASSWORD:-}" ]; then
    db_ready=0
    echo "Database env vars are incomplete. Skipping WP-CLI install/bootstrap and starting Apache only." >&2
fi

if [ "$db_ready" -eq 1 ] && [ ! -f /var/www/html/wp-config.php ]; then
    wp config create \
        --allow-root \
        --path=/var/www/html \
        --dbname="${WORDPRESS_DB_NAME:-wordpress}" \
        --dbuser="${WORDPRESS_DB_USER:-wordpress}" \
        --dbpass="${WORDPRESS_DB_PASSWORD:-}" \
        --dbhost="${WORDPRESS_DB_HOST:-localhost}" \
        --skip-check
fi

if [ -f /var/www/html/wp-config.php ]; then
    insert_wp_config_line /var/www/html/wp-config.php "define( 'DB_ENGINE', 'pgsql' );"
    insert_wp_config_line /var/www/html/wp-config.php "require_once ABSPATH . 'wp-content/wp-config-secrets.php';"
fi

core_installed=0
if [ "$db_ready" -eq 1 ] && wp core is-installed --allow-root --path=/var/www/html >/dev/null 2>&1; then
    core_installed=1
fi

auto_install_core=0
case "${WORDPRESS_AUTO_INSTALL:-false}" in
    1|true|TRUE|yes|YES|on|ON)
        auto_install_core=1
        ;;
esac

bootstrap_marker="/var/www/html/wp-content/.wp-bootstrap-installed"
if [ "$core_installed" -eq 1 ]; then
    touch "$bootstrap_marker"
fi

if [ "$db_ready" -eq 1 ] && [ "$core_installed" -eq 0 ] && [ "$auto_install_core" -eq 1 ] && [ -f "$bootstrap_marker" ]; then
    echo "Bootstrap marker exists; skipping wp core install retry." >&2
fi

if [ "$db_ready" -eq 1 ] && [ "$core_installed" -eq 0 ] && [ "$auto_install_core" -eq 0 ]; then
    echo "WORDPRESS_AUTO_INSTALL is disabled; skipping wp core install." >&2
fi

if [ "$db_ready" -eq 1 ] && [ "$core_installed" -eq 0 ] && [ "$auto_install_core" -eq 1 ] && [ ! -f "$bootstrap_marker" ]; then
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

    if wp core install \
        --allow-root \
        --path=/var/www/html \
        --url="${WORDPRESS_URL:-http://localhost:8080}" \
        --title="${WORDPRESS_SITE_TITLE:-WordPress}" \
        --admin_user="${WORDPRESS_ADMIN_USER:-admin}" \
        --admin_password="$admin_password" \
        --admin_email="${WORDPRESS_ADMIN_EMAIL:-admin@example.com}"; then
        touch "$bootstrap_marker"
        core_installed=1
    else
        echo "wp core install failed; continuing to start Apache." >&2
    fi
fi

if [ "$db_ready" -eq 1 ] && [ "$core_installed" -eq 1 ]; then
    wp plugin is-active wp-pgsql-database --allow-root --path=/var/www/html >/dev/null 2>&1 || \
        wp plugin activate wp-pgsql-database --allow-root --path=/var/www/html || true

    wp plugin is-active s3-uploads --allow-root --path=/var/www/html >/dev/null 2>&1 || \
        wp plugin activate s3-uploads --allow-root --path=/var/www/html || true
fi

if [ "$#" -eq 0 ]; then
    set -- apache2-foreground
fi

# Honor App Platform forwarded HTTPS headers so WordPress generates https URLs.
cat > /etc/apache2/conf-available/app-platform-https.conf <<'APACHECONF'
SetEnvIf X-Forwarded-Proto "https" HTTPS=on
APACHECONF
a2enconf app-platform-https >/dev/null 2>&1 || true

listen_port="${PORT:-80}"
if [ -n "$listen_port" ] && [ "$listen_port" != "80" ]; then
    sed -ri "s/^Listen 80$/Listen ${listen_port}/" /etc/apache2/ports.conf
    sed -ri "s/:80>/:${listen_port}>/g" /etc/apache2/sites-available/000-default.conf
    if [ -f /etc/apache2/sites-available/default-ssl.conf ]; then
        sed -ri "s/:443>/:${listen_port}>/g" /etc/apache2/sites-available/default-ssl.conf
    fi
fi

if ! grep -q '^ServerName ' /etc/apache2/apache2.conf; then
    printf '\nServerName %s\n' "${SERVER_NAME:-localhost}" >> /etc/apache2/apache2.conf
fi

chown -R www-data:www-data /var/www/html/wp-content

exec "$@"
SH

chmod +x /usr/local/bin/wordpress-bootstrap.sh

exec docker-entrypoint.sh sh /usr/local/bin/wordpress-bootstrap.sh "$@"