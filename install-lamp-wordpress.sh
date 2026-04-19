#!/usr/bin/env bash
# =============================================================================
# install-lamp-wordpress.sh
# Full LAMP stack installer for Debian 13 (Trixie)
# Installs: Apache2, MySQL 8, PHP 8.2, WordPress, phpMyAdmin
#
# Usage:
#   sudo bash install-lamp-wordpress.sh [options]
#
# Options:
#   --domain    DOMAIN     Domain name            (default: localhost)
#   --db-name   DB_NAME    WordPress DB name      (default: wordpress)
#   --db-user   DB_USER    WordPress DB user      (default: wpuser)
#   --db-pass   DB_PASS    WordPress DB password  (auto-generated)
#   --wp-admin  WP_ADMIN   WP admin username      (default: admin)
#   --wp-pass   WP_PASS    WP admin password      (auto-generated)
#   --wp-email  WP_EMAIL   WP admin email         (default: admin@localhost)
#   --pma-pass  PMA_PASS   phpMyAdmin ctrl pass   (auto-generated)
#   --skip-ssl             Skip Let's Encrypt SSL
#   --help                 Show this help
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# --------------------------------------------------------------------------- #
# Colour / logging helpers
# --------------------------------------------------------------------------- #
RED='\033[0;31]'; GREEN='\033[0;32]'; YELLOW='\033[1;33]'
CYAN='\033[0;36]'; BOLD='\033[1m'; RESET='\033[0m'

LOG_FILE="/var/log/lamp-install.log"
CREDS_FILE="/root/.lamp-credentials"

_ts()      { date '+%Y-%m-%d %H:%M:%S'; }
info()     { echo -e "$(_ts) ${CYAN}[INFO]${RESET}  $*" | tee -a "${LOG_FILE}"; }
ok()       { echo -e "$(_ts) ${GREEN}[ OK ]${RESET}  $*" | tee -a "${LOG_FILE}"; }
warn()     { echo -e "$(_ts) ${YELLOW}[WARN]${RESET}  $*" | tee -a "${LOG_FILE}"; }
die()      { echo -e "$(_ts) ${RED}[FAIL]${RESET}  $*" | tee -a "${LOG_FILE}" >&2; exit 1; }
section()  {
    local msg="══  $*  ══"
    echo -e "\n${BOLD}${CYAN}${msg}${RESET}" | tee -a "${LOG_FILE}"
}

# --------------------------------------------------------------------------- #
# Trap — catch unexpected errors and report the line number
# --------------------------------------------------------------------------- #
_on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    echo -e "\n${RED}[FATAL]${RESET} Unexpected error on line ${BOLD}${line_no}${RESET} "\
            "(exit code ${exit_code})." | tee -a "${LOG_FILE}" >&2
    echo -e "        Check the install log for details: ${BOLD}${LOG_FILE}${RESET}" >&2
    exit "${exit_code}"
}
trap '_on_error ${LINENO}' ERR

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
gen_pass() { tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom 2>/dev/null | head -c 24 || true; }

# Run a command, log its output, and die with a friendly message on failure
run() {
    local desc="$1"; shift
    info "Running: ${desc}"
    if ! "$@" >> "${LOG_FILE}" 2>&1; then
        die "Step failed: ${desc}\n        Last log lines:\n$(tail -5 "${LOG_FILE}" | sed 's/^/          /')"
    fi
}

# Require a binary to exist in PATH
require_bin() {
    command -v "$1" &>/dev/null || die "Required binary not found: $1 — install it and retry."
}

# =============================================================================
# BLOCK 0 — Argument parsing & pre-flight validation
# =============================================================================
block_preflight() {
    section "BLOCK 0 — Pre-flight checks"

    # ── Root check ───────────────────────────────────────────────────────────
    [[ $EUID -eq 0 ]] || die "This script must be run as root.  Use: sudo bash $0"

    # ── OS check ─────────────────────────────────────────────────────────────
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        [[ "${ID:-}"         == "debian" ]] \
            || warn "This script targets Debian; detected OS: ${PRETTY_NAME:-unknown}."
        [[ "${VERSION_ID:-}" == "13"     ]] \
            || warn "Tested on Debian 13 (Trixie); detected version: ${VERSION_ID:-unknown}."
    else
        warn "/etc/os-release not found — cannot verify OS."
    fi

    # ── Minimum disk space (2 GB) ─────────────────────────────────────────────
    local avail_kb
    avail_kb=$(df --output=avail / | tail -1)
    (( avail_kb >= 2097152 )) \
        || die "Insufficient disk space. Need at least 2 GB free on /; "\
               "found $(( avail_kb / 1024 )) MB."

    # ── Network connectivity ──────────────────────────────────────────────────
    info "Checking internet connectivity …"
    ping -c1 -W5 8.8.8.8 &>/dev/null \
        || die "No internet access detected. Check your network configuration."

    # ── Required base tools ───────────────────────────────────────────────────
    for bin in curl tar rsync perl; do
        require_bin "${bin}"
    done

    # ── Ensure log file is writable ───────────────────────────────────────────
    touch "${LOG_FILE}" 2>/dev/null \
        || die "Cannot write to log file: ${LOG_FILE}"
    chmod 640 "${LOG_FILE}"

    ok "Pre-flight checks passed."
}

block_parse_args() {
    section "BLOCK 0b — Argument parsing"

    # Defaults
    DOMAIN="localhost"
    DB_NAME="wordpress"
    DB_USER="wpuser"
    DB_PASS=""
    WP_ADMIN="admin"
    WP_PASS=""
    WP_EMAIL="admin@localhost"
    PMA_PASS=""
    SKIP_SSL=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain)   DOMAIN="${2:?'--domain requires a value'}";   shift 2 ;;
            --db-name)  DB_NAME="${2:?'--db-name requires a value'}";  shift 2 ;;
            --db-user)  DB_USER="${2:?'--db-user requires a value'}";  shift 2 ;;
            --db-pass)  DB_PASS="${2:?'--db-pass requires a value'}";  shift 2 ;;
            --wp-admin) WP_ADMIN="${2:?'--wp-admin requires a value'}"; shift 2 ;;
            --wp-pass)  WP_PASS="${2:?'--wp-pass requires a value'}";  shift 2 ;;
            --wp-email) WP_EMAIL="${2:?'--wp-email requires a value'}"; shift 2 ;;
            --pma-pass) PMA_PASS="${2:?'--pma-pass requires a value'}"; shift 2 ;;
            --skip-ssl) SKIP_SSL=true; shift ;;
            --help)
                grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -25
                exit 0 ;;
            *) die "Unknown option: '$1'\nRun with --help for usage." ;;
        esac
    done

    # ── Validate domain ───────────────────────────────────────────────────────
    if [[ "${DOMAIN}" != "localhost" ]]; then
        [[ "${DOMAIN}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]] \
            || die "Invalid domain name: '${DOMAIN}'. "\
                   "Use a fully-qualified domain (e.g. example.com) or 'localhost'."
    fi

    # ── Validate email ────────────────────────────────────────────────────────
    [[ "${WP_EMAIL}" =~ ^[^@]+@[^@]+\.[^@]+$ ]] \
        || die "Invalid email address: '${WP_EMAIL}'."

    # ── Validate DB name (MySQL identifier rules) ─────────────────────────────
    [[ "${DB_NAME}" =~ ^[a-zA-Z0-9_]{1,64}$ ]] \
        || die "Invalid DB name '${DB_NAME}'. Use only letters, digits, underscores (max 64 chars)."

    # ── Validate DB username ──────────────────────────────────────────────────
    [[ "${DB_USER}" =~ ^[a-zA-Z0-9_]{1,32}$ ]] \
        || die "Invalid DB user '${DB_USER}'. Use only letters, digits, underscores (max 32 chars)."

    # ── Auto-generate missing passwords ──────────────────────────────────────
    [[ -n "${DB_PASS}"  ]] || { DB_PASS="$(gen_pass)";  info "DB password auto-generated."; }
    [[ -n "${WP_PASS}"  ]] || { WP_PASS="$(gen_pass)";  info "WP admin password auto-generated."; }
    [[ -n "${PMA_PASS}" ]] || { PMA_PASS="$(gen_pass)"; info "phpMyAdmin control password auto-generated."; }

    MYSQL_ROOT_PASS="$(gen_pass)"
    WP_DIR="/var/www/html/${DOMAIN}"
    PMA_VERSION="5.2.1"
    PMA_DIR="/usr/share/phpmyadmin"

    if [[ "${DOMAIN}" == "localhost" ]]; then
        WP_SITEURL="http://localhost"
        SKIP_SSL=true
    else
        WP_SITEURL="https://${DOMAIN}"
    fi

    # ── Confirm before proceeding ─────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Installation summary${RESET}"
    echo    "  ─────────────────────────────────────────"
    echo -e "  Domain         : ${BOLD}${DOMAIN}${RESET}"
    echo -e "  Web root       : ${BOLD}${WP_DIR}${RESET}"
    echo -e "  DB name        : ${BOLD}${DB_NAME}${RESET}"
    echo -e "  DB user        : ${BOLD}${DB_USER}${RESET}"
    echo -e "  WP admin user  : ${BOLD}${WP_ADMIN}${RESET}"
    echo -e "  WP admin email : ${BOLD}${WP_EMAIL}${RESET}"
    echo -e "  SSL            : ${BOLD}$( [[ $SKIP_SSL == true ]] && echo 'skipped' || echo "Let's Encrypt" )${RESET}"
    echo    "  ─────────────────────────────────────────"
    echo ""
    read -rp "  Continue? [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { info "Installation aborted by user."; exit 0; }

    ok "Arguments validated."
}

# =============================================================================
# BLOCK 1 — System update
# =============================================================================
block_system_update() {
    section "BLOCK 1 — System update"

    info "Updating package lists …"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "${LOG_FILE}" 2>&1 \
        || die "apt-get update failed. Check your sources.list and network connectivity.\n"\
               "Details: $(tail -5 "${LOG_FILE}")"

    info "Upgrading installed packages …"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq >> "${LOG_FILE}" 2>&1 \
        || die "apt-get upgrade failed. There may be held or conflicting packages.\n"\
               "Try running: apt-get upgrade manually to inspect errors."

    ok "System packages up to date."
}

# =============================================================================
# BLOCK 2 — Apache
# =============================================================================
block_apache() {
    section "BLOCK 2 — Apache"

    info "Installing Apache2 …"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2 >> "${LOG_FILE}" 2>&1 \
        || die "Failed to install apache2. Check apt output in ${LOG_FILE}."

    for mod in rewrite ssl headers; do
        info "Enabling Apache module: ${mod} …"
        a2enmod "${mod}" >> "${LOG_FILE}" 2>&1 \
            || die "Failed to enable Apache module '${mod}'.\n"\
                   "Run: apache2ctl -M to see loaded modules."
    done

    info "Enabling and starting Apache …"
    systemctl enable apache2 >> "${LOG_FILE}" 2>&1 \
        || die "Failed to enable Apache service on boot."
    systemctl start apache2 >> "${LOG_FILE}" 2>&1 \
        || die "Apache failed to start. Check: journalctl -xe -u apache2"

    # Verify Apache is actually listening
    sleep 1
    systemctl is-active --quiet apache2 \
        || die "Apache service started but is not active. "\
               "Check: journalctl -xe -u apache2"

    ok "Apache installed and running."
}

# =============================================================================
# BLOCK 3 — MySQL
# =============================================================================
block_mysql() {
    section "BLOCK 3 — MySQL 8"

    info "Installing MySQL server …"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-server >> "${LOG_FILE}" 2>&1 \
        || die "Failed to install mysql-server. Check apt output in ${LOG_FILE}."

    info "Enabling and starting MySQL …"
    systemctl enable mysql >> "${LOG_FILE}" 2>&1 \
        || die "Failed to enable MySQL service on boot."
    systemctl start mysql >> "${LOG_FILE}" 2>&1 \
        || die "MySQL failed to start. Check: journalctl -xe -u mysql"

    systemctl is-active --quiet mysql \
        || die "MySQL service started but is not active. "\
               "Check: journalctl -xe -u mysql"

    # ── Secure root account ───────────────────────────────────────────────────
    info "Securing MySQL root account …"
    mysql --user=root 2>>"${LOG_FILE}" <<-MYSQL || \
        die "Failed to set MySQL root password. Is MySQL already secured?\n"\
            "If so, run this script with an existing --db-pass or reset root manually."
        ALTER USER 'root'@'localhost'
            IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
        FLUSH PRIVILEGES;
MYSQL

    # ── Remove insecure defaults ──────────────────────────────────────────────
    info "Removing anonymous users, test database …"
    mysql --user=root --password="${MYSQL_ROOT_PASS}" 2>>"${LOG_FILE}" <<-MYSQL \
        || die "Failed to remove MySQL insecure defaults. Check ${LOG_FILE} for SQL errors."
        DELETE FROM mysql.user WHERE User='';
        DELETE FROM mysql.user
            WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
        FLUSH PRIVILEGES;
MYSQL

    # ── Verify the root credentials we just set actually work ─────────────────
    info "Verifying MySQL root credentials …"
    mysql --user=root --password="${MYSQL_ROOT_PASS}" \
          --execute="SELECT 1;" >> "${LOG_FILE}" 2>&1 \
        || die "MySQL root credential verification failed. "\
               "The password may not have been set correctly."

    # ── Create WordPress database ─────────────────────────────────────────────
    info "Creating WordPress database '${DB_NAME}' …"
    mysql --user=root --password="${MYSQL_ROOT_PASS}" 2>>"${LOG_FILE}" <<-MYSQL \
        || die "Failed to create WordPress database '${DB_NAME}'."
        CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
            CHARACTER SET utf8mb4
            COLLATE utf8mb4_unicode_ci;
MYSQL

    # ── Create WordPress DB user ──────────────────────────────────────────────
    info "Creating WordPress DB user '${DB_USER}' …"
    mysql --user=root --password="${MYSQL_ROOT_PASS}" 2>>"${LOG_FILE}" <<-MYSQL \
        || die "Failed to create DB user '${DB_USER}'.\n"\
               "The user may already exist. Check: SELECT User,Host FROM mysql.user;"
        CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
            IDENTIFIED BY '${DB_PASS}';
        GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
MYSQL

    # ── Verify WordPress DB user can connect ──────────────────────────────────
    info "Verifying WordPress DB user credentials …"
    mysql --user="${DB_USER}" --password="${DB_PASS}" \
          --database="${DB_NAME}" \
          --execute="SELECT 1;" >> "${LOG_FILE}" 2>&1 \
        || die "WordPress DB user '${DB_USER}' cannot connect to '${DB_NAME}'.\n"\
               "Check grants: SHOW GRANTS FOR '${DB_USER}'@'localhost';"

    # ── Create phpMyAdmin control user ────────────────────────────────────────
    info "Creating phpMyAdmin control user …"
    mysql --user=root --password="${MYSQL_ROOT_PASS}" 2>>"${LOG_FILE}" <<-MYSQL \
        || die "Failed to create phpMyAdmin control user."
        CREATE USER IF NOT EXISTS 'phpmyadmin'@'localhost'
            IDENTIFIED BY '${PMA_PASS}';
        GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER
            ON phpmyadmin.* TO 'phpmyadmin'@'localhost';
        FLUSH PRIVILEGES;
MYSQL

    ok "MySQL configured; databases and users created."
}

# =============================================================================
# BLOCK 4 — PHP
# =============================================================================
block_php() {
    section "BLOCK 4 — PHP 8.2"

    local php_packages=(
        php php-mysql php-curl php-gd php-mbstring php-xml
        php-xmlrpc php-soap php-intl php-zip php-bcmath
        php-imagick php-json php-common libapache2-mod-php
    )

    info "Installing PHP and extensions: ${php_packages[*]} …"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        "${php_packages[@]}" >> "${LOG_FILE}" 2>&1 \
        || die "PHP installation failed.\n"\
               "Try running: apt-get install ${php_packages[*]}\n"\
               "to identify which package is causing the error."

    # ── Verify PHP CLI is functional ──────────────────────────────────────────
    info "Verifying PHP installation …"
    php --version >> "${LOG_FILE}" 2>&1 \
        || die "PHP installed but 'php --version' failed. "\
               "The installation may be corrupt."

    # ── Verify critical extensions loaded ─────────────────────────────────────
    for ext in pdo_mysql curl gd mbstring xml zip; do
        php -m 2>/dev/null | grep -qi "^${ext}$" \
            || warn "PHP extension '${ext}' does not appear to be loaded. "\
                    "WordPress may not function correctly."
    done

    # ── Tune php.ini ──────────────────────────────────────────────────────────
    local php_ini
    php_ini="$(php -i 2>/dev/null | grep "^Loaded Configuration File" | awk '{print $NF}')"

    if [[ -z "${php_ini}" || ! -f "${php_ini}" ]]; then
        warn "Could not locate php.ini automatically — skipping tuning.\n"\
             "Locate it with: php --ini and set upload_max_filesize, "\
             "post_max_size, memory_limit manually."
    else
        info "Tuning ${php_ini} …"
        # Back up first
        cp "${php_ini}" "${php_ini}.bak" \
            || warn "Could not back up php.ini — proceeding anyway."

        declare -A PHP_SETTINGS=(
            [upload_max_filesize]="64M"
            [post_max_size]="64M"
            [memory_limit]="256M"
            [max_execution_time]="120"
            [max_input_time]="120"
        )
        for key in "${!PHP_SETTINGS[@]}"; do
            local val="${PHP_SETTINGS[$key]}"
            if grep -qE "^;?${key}\s*=" "${php_ini}"; then
                sed -i "s|^;*${key}\s*=.*|${key} = ${val}|" "${php_ini}" \
                    || warn "Could not set PHP setting '${key}' in ${php_ini}."
            else
                echo "${key} = ${val}" >> "${php_ini}" \
                    || warn "Could not append PHP setting '${key}' to ${php_ini}."
            fi
        done
        ok "PHP settings tuned."
    fi

    info "Reloading Apache to pick up PHP module …"
    systemctl reload apache2 >> "${LOG_FILE}" 2>&1 \
        || die "Apache failed to reload after PHP install. "\
               "Check: apachectl configtest"

    ok "PHP installed and configured."
}

# =============================================================================
# BLOCK 5 — WordPress
# =============================================================================
block_wordpress() {
    section "BLOCK 5 — WordPress"

    local tmp_dir
    tmp_dir="$(mktemp -d)" || die "Failed to create a temporary directory."
    # Clean up temp dir on exit
    trap "rm -rf '${tmp_dir}'; _on_error \${LINENO}" ERR
    trap "rm -rf '${tmp_dir}'" EXIT

    # ── Download ──────────────────────────────────────────────────────────────
    info "Downloading WordPress …"
    curl -sSL --retry 3 --retry-delay 5 \
         "https://wordpress.org/latest.tar.gz" \
         -o "${tmp_dir}/wordpress-latest.tar.gz" \
        || die "Failed to download WordPress from wordpress.org.\n"\
               "Check network connectivity or try again later."

    # ── Verify the archive is valid ───────────────────────────────────────────
    info "Verifying WordPress archive integrity …"
    tar -tzf "${tmp_dir}/wordpress-latest.tar.gz" >> "${LOG_FILE}" 2>&1 \
        || die "Downloaded WordPress archive is corrupt or incomplete.\n"\
               "Delete the file and retry."

    # ── Extract ───────────────────────────────────────────────────────────────
    info "Extracting WordPress …"
    tar -xzf "${tmp_dir}/wordpress-latest.tar.gz" -C "${tmp_dir}" >> "${LOG_FILE}" 2>&1 \
        || die "Failed to extract WordPress archive."

    [[ -d "${tmp_dir}/wordpress" ]] \
        || die "Extraction appeared to succeed but '${tmp_dir}/wordpress' was not created."

    # ── Deploy ────────────────────────────────────────────────────────────────
    info "Deploying WordPress to ${WP_DIR} …"
    mkdir -p "${WP_DIR}" \
        || die "Failed to create web root directory: ${WP_DIR}"

    rsync -a --delete "${tmp_dir}/wordpress/" "${WP_DIR}/" >> "${LOG_FILE}" 2>&1 \
        || die "Failed to copy WordPress files to ${WP_DIR}.\n"\
               "Check disk space and permissions."

    # ── Verify key WordPress files are present ────────────────────────────────
    for f in wp-config-sample.php wp-login.php wp-includes/version.php; do
        [[ -f "${WP_DIR}/${f}" ]] \
            || die "WordPress file missing after deploy: ${WP_DIR}/${f}\n"\
                   "The download may have been incomplete."
    done

    # ── wp-config.php ─────────────────────────────────────────────────────────
    info "Creating wp-config.php …"
    cp "${WP_DIR}/wp-config-sample.php" "${WP_DIR}/wp-config.php" \
        || die "Failed to copy wp-config-sample.php to wp-config.php."

    sed -i "s/database_name_here/${DB_NAME}/" "${WP_DIR}/wp-config.php" \
        || die "Failed to set DB_NAME in wp-config.php."
    sed -i "s/username_here/${DB_USER}/"      "${WP_DIR}/wp-config.php" \
        || die "Failed to set DB_USER in wp-config.php."
    sed -i "s/password_here/${DB_PASS}/"      "${WP_DIR}/wp-config.php" \
        || die "Failed to set DB_PASS in wp-config.php."

    # ── Fetch and inject fresh salts ──────────────────────────────────────────
    info "Fetching WordPress secret keys/salts …"
    local salts
    salts="$(curl -sSL --retry 3 --retry-delay 5 \
             "https://api.wordpress.org/secret-key/1.1/salt/" 2>/dev/null)" \
        || warn "Could not fetch salts from wordpress.org — placeholder salts left in place.\n"\
                "Replace them manually: https://api.wordpress.org/secret-key/1.1/salt/"

    if [[ -n "${salts}" ]]; then
        # Remove the 8 placeholder lines and insert fresh salts
        perl -i -0pe \
            "s|define\(\s*'AUTH_KEY'.*?(?=\\/\\*\s|\$)|${salts}\n|s" \
            "${WP_DIR}/wp-config.php" 2>>"${LOG_FILE}" \
            || warn "Could not auto-replace salts — set them manually in wp-config.php."
    fi

    # ── Hardening constants ───────────────────────────────────────────────────
    info "Applying wp-config.php hardening constants …"
    cat >> "${WP_DIR}/wp-config.php" <<'WPCONF'

/* --- Security hardening (added by installer) --- */
define( 'DISALLOW_FILE_EDIT',  true   );
define( 'WP_AUTO_UPDATE_CORE', 'minor' );
define( 'FS_METHOD',           'direct' );
define( 'WP_DEBUG',            false   );
define( 'FORCE_SSL_ADMIN',     false   ); /* set true once SSL is active */
WPCONF
    # shellcheck disable=SC2181
    [[ $? -eq 0 ]] || die "Failed to append hardening constants to wp-config.php."

    # ── Permissions ───────────────────────────────────────────────────────────
    info "Setting WordPress file ownership and permissions …"
    chown -R www-data:www-data "${WP_DIR}" \
        || die "Failed to set ownership on ${WP_DIR}."
    find "${WP_DIR}" -type d -exec chmod 755 {} \; \
        || die "Failed to set directory permissions in ${WP_DIR}."
    find "${WP_DIR}" -type f -exec chmod 644 {} \; \
        || die "Failed to set file permissions in ${WP_DIR}."
    chmod 640 "${WP_DIR}/wp-config.php" \
        || die "Failed to restrict permissions on wp-config.php."

    # ── .htaccess ─────────────────────────────────────────────────────────────
    info "Creating .htaccess …"
    cat > "${WP_DIR}/.htaccess" <<'HTACCESS'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>

# Block XML-RPC (common attack vector)
<Files xmlrpc.php>
    Require all denied
</Files>

# Protect wp-config.php
<Files wp-config.php>
    Require all denied
</Files>

# Disable directory listing
Options -Indexes
# END WordPress
HTACCESS
    chown www-data:www-data "${WP_DIR}/.htaccess" \
        || die "Failed to set ownership on .htaccess."

    ok "WordPress deployed and configured."
}

# =============================================================================
# BLOCK 6 — phpMyAdmin
# =============================================================================
block_phpmyadmin() {
    section "BLOCK 6 — phpMyAdmin ${PMA_VERSION}"

    local tmp_dir
    tmp_dir="$(mktemp -d)" || die "Failed to create a temporary directory for phpMyAdmin."
    trap "rm -rf '${tmp_dir}'; _on_error \${LINENO}" ERR

    local pma_url="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"

    # ── Download ──────────────────────────────────────────────────────────────
    info "Downloading phpMyAdmin ${PMA_VERSION} …"
    curl -sSL --retry 3 --retry-delay 5 \
         "${pma_url}" -o "${tmp_dir}/phpmyadmin.tar.gz" \
        || die "Failed to download phpMyAdmin from files.phpmyadmin.net.\n"\
               "URL attempted: ${pma_url}"

    # ── Verify archive ────────────────────────────────────────────────────────
    info "Verifying phpMyAdmin archive …"
    tar -tzf "${tmp_dir}/phpmyadmin.tar.gz" >> "${LOG_FILE}" 2>&1 \
        || die "phpMyAdmin archive is corrupt or incomplete.\n"\
               "Remove the temp file and retry."

    # ── Extract and install ───────────────────────────────────────────────────
    info "Extracting phpMyAdmin …"
    tar -xzf "${tmp_dir}/phpmyadmin.tar.gz" -C "${tmp_dir}" >> "${LOG_FILE}" 2>&1 \
        || die "Failed to extract phpMyAdmin archive."

    local extracted_dir="${tmp_dir}/phpMyAdmin-${PMA_VERSION}-all-languages"
    [[ -d "${extracted_dir}" ]] \
        || die "phpMyAdmin extraction appeared to succeed but expected directory\n"\
               "'${extracted_dir}' was not found."

    info "Installing phpMyAdmin to ${PMA_DIR} …"
    mkdir -p "${PMA_DIR}" \
        || die "Failed to create phpMyAdmin directory: ${PMA_DIR}"

    rsync -a --delete "${extracted_dir}/" "${PMA_DIR}/" >> "${LOG_FILE}" 2>&1 \
        || die "Failed to copy phpMyAdmin files to ${PMA_DIR}."

    # ── Verify key files ──────────────────────────────────────────────────────
    for f in index.php libraries/classes/Config.php sql/create_tables.sql; do
        [[ -f "${PMA_DIR}/${f}" ]] \
            || die "phpMyAdmin file missing after installation: ${PMA_DIR}/${f}"
    done

    # ── Temp directory ────────────────────────────────────────────────────────
    info "Creating phpMyAdmin tmp directory …"
    mkdir -p "${PMA_DIR}/tmp" \
        || die "Failed to create phpMyAdmin tmp directory."
    chown www-data:www-data "${PMA_DIR}/tmp" \
        || die "Failed to set ownership on phpMyAdmin tmp directory."
    chmod 750 "${PMA_DIR}/tmp" \
        || die "Failed to set permissions on phpMyAdmin tmp directory."

    # ── config.inc.php ────────────────────────────────────────────────────────
    info "Writing phpMyAdmin config.inc.php …"
    local blowfish_secret
    blowfish_secret="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)" \
        || die "Failed to generate phpMyAdmin blowfish secret."

    cat > "${PMA_DIR}/config.inc.php" <<PMACONF || \
        die "Failed to write ${PMA_DIR}/config.inc.php."
<?php
\$cfg['blowfish_secret'] = '${blowfish_secret}';

\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type']       = 'cookie';
\$cfg['Servers'][\$i]['host']            = '127.0.0.1';
\$cfg['Servers'][\$i]['compress']        = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['Servers'][\$i]['controluser']     = 'phpmyadmin';
\$cfg['Servers'][\$i]['controlpass']     = '${PMA_PASS}';
\$cfg['Servers'][\$i]['pmadb']           = 'phpmyadmin';
\$cfg['Servers'][\$i]['bookmarktable']   = 'pma__bookmark';
\$cfg['Servers'][\$i]['relation']        = 'pma__relation';
\$cfg['Servers'][\$i]['table_info']      = 'pma__table_info';
\$cfg['Servers'][\$i]['table_coords']    = 'pma__table_coords';
\$cfg['Servers'][\$i]['pdf_pages']       = 'pma__pdf_pages';
\$cfg['Servers'][\$i]['column_info']     = 'pma__column_info';
\$cfg['Servers'][\$i]['history']         = 'pma__history';
\$cfg['Servers'][\$i]['table_uiprefs']   = 'pma__table_uiprefs';
\$cfg['Servers'][\$i]['tracking']        = 'pma__tracking';
\$cfg['Servers'][\$i]['userconfig']      = 'pma__userconfig';
\$cfg['Servers'][\$i]['recent']          = 'pma__recent';
\$cfg['Servers'][\$i]['favorite']        = 'pma__favorite';
\$cfg['Servers'][\$i]['users']           = 'pma__users';
\$cfg['Servers'][\$i]['usergroups']      = 'pma__usergroups';
\$cfg['Servers'][\$i]['navigationhide']  = 'pma__navigationhide';
\$cfg['Servers'][\$i]['savedsearches']   = 'pma__savedsearches';
\$cfg['Servers'][\$i]['central_columns'] = 'pma__central_columns';
\$cfg['Servers'][\$i]['designer_settings']= 'pma__designer_settings';
\$cfg['Servers'][\$i]['export_templates']= 'pma__export_templates';

\$cfg['UploadDir'] = '';
\$cfg['SaveDir']   = '';
\$cfg['TempDir']   = '${PMA_DIR}/tmp';
\$cfg['CheckConfigurationPermissions'] = false;
PMACONF

    chown www-data:www-data "${PMA_DIR}/config.inc.php" \
        || die "Failed to set ownership on config.inc.php."
    chmod 640 "${PMA_DIR}/config.inc.php" \
        || die "Failed to restrict permissions on config.inc.php."

    # ── Import control tables schema ──────────────────────────────────────────
    info "Importing phpMyAdmin control tables schema …"
    mysql --user=root --password="${MYSQL_ROOT_PASS}" \
          < "${PMA_DIR}/sql/create_tables.sql" >> "${LOG_FILE}" 2>&1 \
        || die "Failed to import phpMyAdmin control tables.\n"\
               "Try manually: mysql -u root -p < ${PMA_DIR}/sql/create_tables.sql"

    chown -R www-data:www-data "${PMA_DIR}" \
        || die "Failed to set ownership on ${PMA_DIR}."

    rm -rf "${tmp_dir}"
    ok "phpMyAdmin ${PMA_VERSION} installed."
}

# =============================================================================
# BLOCK 7 — Apache virtual host
# =============================================================================
block_vhost() {
    section "BLOCK 7 — Apache virtual host"

    local vhost_conf="/etc/apache2/sites-available/${DOMAIN}.conf"
    local server_alias_line=""
    [[ "${DOMAIN}" != "localhost" ]] && \
        server_alias_line="    ServerAlias www.${DOMAIN}"

    info "Writing virtual host config: ${vhost_conf} …"
    cat > "${vhost_conf}" <<VHOST || die "Failed to write virtual host config: ${vhost_conf}"
<VirtualHost *:80>
    ServerName ${DOMAIN}
${server_alias_line}
    DocumentRoot ${WP_DIR}

    <Directory ${WP_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # phpMyAdmin — restrict to a trusted IP in production:
    #   Replace "Require all granted" with "Require ip 203.0.113.10"
    Alias /phpmyadmin ${PMA_DIR}
    <Directory ${PMA_DIR}>
        Options -Indexes
        AllowOverride None
        Require all granted
    </Directory>
    <Directory ${PMA_DIR}/libraries>
        Require all denied
    </Directory>
    <Directory ${PMA_DIR}/templates>
        Require all denied
    </Directory>
    <Directory ${PMA_DIR}/setup>
        Require all denied
    </Directory>

    Header always set X-Content-Type-Options  "nosniff"
    Header always set X-Frame-Options         "SAMEORIGIN"
    Header always set X-XSS-Protection        "1; mode=block"
    Header always set Referrer-Policy         "strict-origin-when-cross-origin"

    ErrorLog  \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>
VHOST

    # ── Validate config before enabling ──────────────────────────────────────
    info "Validating Apache configuration syntax …"
    apachectl configtest >> "${LOG_FILE}" 2>&1 \
        || die "Apache configuration test failed after writing vhost.\n"\
               "Check syntax: apachectl configtest\n"\
               "Review: ${vhost_conf}"

    info "Enabling site: ${DOMAIN} …"
    a2ensite "${DOMAIN}.conf" >> "${LOG_FILE}" 2>&1 \
        || die "Failed to enable site '${DOMAIN}.conf'.\n"\
               "Check that the config file exists: ${vhost_conf}"

    info "Disabling default site …"
    a2dissite 000-default.conf >> "${LOG_FILE}" 2>&1 \
        || warn "Could not disable default site (may not exist — this is OK)."

    # ── Final config test + reload ────────────────────────────────────────────
    info "Running final Apache config test …"
    apachectl configtest >> "${LOG_FILE}" 2>&1 \
        || die "Apache config is invalid after enabling site. "\
               "Run: apachectl configtest for details."

    info "Reloading Apache …"
    systemctl reload apache2 >> "${LOG_FILE}" 2>&1 \
        || die "Apache reload failed. Check: journalctl -xe -u apache2"

    systemctl is-active --quiet apache2 \
        || die "Apache is no longer active after reload. "\
               "Check: journalctl -xe -u apache2"

    ok "Virtual host configured and Apache reloaded."
}

# =============================================================================
# BLOCK 8 — SSL (Let's Encrypt)
# =============================================================================
block_ssl() {
    section "BLOCK 8 — SSL (Let's Encrypt)"

    if [[ "${SKIP_SSL}" == "true" ]]; then
        warn "SSL setup skipped."
        warn "When your domain is ready, run:"
        warn "  apt install certbot python3-certbot-apache"
        warn "  certbot --apache -d ${DOMAIN} -d www.${DOMAIN}"
        return 0
    fi

    # ── Check DNS resolves to this server ─────────────────────────────────────
    info "Checking DNS resolution for ${DOMAIN} …"
    local server_ip domain_ip
    server_ip="$(curl -sSL --retry 2 https://api.ipify.org 2>/dev/null)" \
        || warn "Could not determine server public IP — skipping DNS check."
    domain_ip="$(dig +short "${DOMAIN}" A 2>/dev/null | tail -1)" \
        || warn "dig not available — skipping DNS check."

    if [[ -n "${server_ip}" && -n "${domain_ip}" ]]; then
        [[ "${server_ip}" == "${domain_ip}" ]] \
            || warn "DNS mismatch: ${DOMAIN} resolves to ${domain_ip} "\
                    "but this server's IP is ${server_ip}.\n"\
                    "  Certbot may fail — ensure DNS propagation is complete."
    fi

    # ── Install Certbot ───────────────────────────────────────────────────────
    info "Installing Certbot …"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        certbot python3-certbot-apache >> "${LOG_FILE}" 2>&1 \
        || die "Failed to install certbot.\n"\
               "Try: apt-get install certbot python3-certbot-apache"

    # ── Port 80 must be accessible for HTTP challenge ─────────────────────────
    info "Verifying port 80 is accessible …"
    curl -sSL --max-time 5 "http://${DOMAIN}/" -o /dev/null >> "${LOG_FILE}" 2>&1 \
        || warn "Could not reach http://${DOMAIN}/ — Certbot's HTTP challenge may fail.\n"\
                "Ensure port 80 is open in your firewall."

    # ── Run Certbot ───────────────────────────────────────────────────────────
    info "Requesting SSL certificate for ${DOMAIN} …"
    certbot --apache \
            --non-interactive \
            --agree-tos \
            --email "${WP_EMAIL}" \
            --redirect \
            -d "${DOMAIN}" \
            -d "www.${DOMAIN}" >> "${LOG_FILE}" 2>&1 \
        || die "Certbot failed to obtain a certificate for ${DOMAIN}.\n"\
               "Common causes:\n"\
               "  • DNS not yet propagated (allow up to 48h)\n"\
               "  • Port 80 blocked by firewall\n"\
               "  • Let's Encrypt rate limit hit (5 certs/domain/week)\n"\
               "Re-run manually: certbot --apache -d ${DOMAIN} -d www.${DOMAIN}"

    # ── Enable FORCE_SSL_ADMIN now that SSL is live ───────────────────────────
    info "Enabling FORCE_SSL_ADMIN in wp-config.php …"
    sed -i "s/define( 'FORCE_SSL_ADMIN',     false )/define( 'FORCE_SSL_ADMIN', true )/" \
        "${WP_DIR}/wp-config.php" \
        || warn "Could not set FORCE_SSL_ADMIN — edit wp-config.php manually."

    # ── Verify HTTPS is working ───────────────────────────────────────────────
    info "Verifying HTTPS response …"
    curl -sSL --max-time 10 "https://${DOMAIN}/" -o /dev/null >> "${LOG_FILE}" 2>&1 \
        || warn "HTTPS check failed — the certificate may need a moment to propagate."

    ok "SSL certificate issued and HTTPS configured."
}

# =============================================================================
# BLOCK 9 — Save credentials
# =============================================================================
block_save_credentials() {
    section "BLOCK 9 — Saving credentials"

    cat > "${CREDS_FILE}" <<CREDS || \
        die "Failed to write credentials file: ${CREDS_FILE}"
# LAMP Stack Credentials — $(date)
# ─────────────────────────────────────────────────────────────
# KEEP THIS FILE SECURE.  Delete it once stored in a vault.
# ─────────────────────────────────────────────────────────────

[MySQL]
  Root password          : ${MYSQL_ROOT_PASS}

[WordPress Database]
  Database               : ${DB_NAME}
  User                   : ${DB_USER}
  Password               : ${DB_PASS}

[WordPress Admin]
  Site URL               : ${WP_SITEURL}
  Admin URL              : ${WP_SITEURL}/wp-admin
  Username               : ${WP_ADMIN}
  Password               : ${WP_PASS}
  Email                  : ${WP_EMAIL}

[phpMyAdmin]
  URL                    : ${WP_SITEURL}/phpmyadmin
  Control user           : phpmyadmin
  Control password       : ${PMA_PASS}
  (Log in with any valid MySQL user, e.g. root or ${DB_USER})

[Paths]
  WordPress root         : ${WP_DIR}
  phpMyAdmin root        : ${PMA_DIR}
  Apache vhost config    : /etc/apache2/sites-available/${DOMAIN}.conf
  Install log            : ${LOG_FILE}
CREDS

    chmod 600 "${CREDS_FILE}" \
        || die "Failed to restrict permissions on credentials file: ${CREDS_FILE}"

    ok "Credentials saved to ${CREDS_FILE} (mode 600)."
}

# =============================================================================
# MAIN — execute all blocks in order
# =============================================================================
main() {
    # Parse args before preflight so --help works without root
    block_parse_args "$@"
    block_preflight
    block_system_update
    block_apache
    block_mysql
    block_php
    block_wordpress
    block_phpmyadmin
    block_vhost
    block_ssl
    block_save_credentials

    # ── Final summary ─────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${GREEN}║       LAMP + WordPress install complete!             ║${RESET}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  WordPress  : ${BOLD}${WP_SITEURL}${RESET}"
    echo -e "  WP Admin   : ${BOLD}${WP_SITEURL}/wp-admin${RESET}"
    echo -e "  phpMyAdmin : ${BOLD}${WP_SITEURL}/phpmyadmin${RESET}"
    echo ""
    echo -e "  Credentials: ${BOLD}${CREDS_FILE}${RESET}"
    echo -e "  Install log: ${BOLD}${LOG_FILE}${RESET}"
    echo ""
    echo -e "  ${YELLOW}Next steps:${RESET}"
    echo    "   1. Visit the WordPress URL above to complete setup."
    echo    "   2. Restrict phpMyAdmin in the Apache vhost to a trusted IP."
    echo    "   3. Run the firewall script to harden the server."
    echo    "   4. Delete ${CREDS_FILE} once credentials are stored safely."
    echo ""
}

main "$@"
