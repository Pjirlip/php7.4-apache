FROM debian:trixie-slim
LABEL maintainer="Philipp Dippel <philipp.dippel@propeller.de>"
SHELL ["/bin/bash", "-c"]

# PHP 7.4 is end-of-life upstream: the official php:7.4 images stopped at 7.4.33 (November 2022) and no
# upstream release contains the fixes for CVE-2026-109618/109619. Ondřej Surý's Debian packages carry the
# security backports (7.4.33-31 of 21 Oct 2026 adds "Avoid state corruption via bailout" on top of 160+
# earlier patches), so this image installs PHP from packages.sury.org instead of building the unpatched
# upstream tarball. Rebuilding the image picks up newer package revisions and Debian security updates.
ARG SURY_REPO_FINGERPRINT=15058500A0235D97F5D10063B188E2B695BD4743
ARG PHP_MIN_PACKAGE_VERSION=1:7.4.33-31

# groupadd/useradd from the essential passwd package: trixie-slim has no adduser wrapper
RUN groupadd --gid 1000 propeller && useradd --system --uid 1000 --gid propeller propeller

ENV PROVISION_CONTEXT="production"
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Berlin
ENV APACHE_LOCK_DIR=/var/lock/apache2
ENV APACHE_LOG_DIR=/var/log/apache2
ENV APACHE_PID_FILE=/var/run/apache2/apache2.pid
ENV APACHE_SERVER_NAME=localhost
ENV APACHE_RUN_USER=propeller
ENV APACHE_RUN_GROUP=propeller
ENV APACHE_RUN_DIR=/var/run/apache2
ENV DOCUMENT_ROOT=/var/www/html
ENV LETSENCRYPT_EMAIL=certbot@propeller.de
ENV PORT=80
# Debian packaging layout: php.ini per SAPI below this directory, shared drop-ins in mods-available
ENV PHP_INI_DIR=/etc/php/7.4
# Apache runtime tuning (K1, K2, H4). An empty APACHE_MAX_REQUEST_WORKERS lets entrypoint.sh derive the
# value from the container memory limit: floor((limit_MiB - BASELINE_MB) / CHILD_MB)
ENV APACHE_MAX_REQUEST_WORKERS="" \
    APACHE_CHILD_MEMORY_MB=100 \
    APACHE_BASELINE_MEMORY_MB=256 \
    APACHE_MIN_SPARE_SERVERS=2 \
    APACHE_MAX_SPARE_SERVERS=4 \
    APACHE_MAX_CONNECTIONS_PER_CHILD=1000 \
    APACHE_TIMEOUT=120 \
    APACHE_ALLOW_OVERRIDE=All

ENV SMTP_SERVER=example.com
ENV SMTP_PORT=25
ENV SMTP_FROM=mail@example.com
ENV PHP_MEMORY_LIMIT=256M
ENV PHP_MAX_EXEC_TIME=240
ENV PHP_POST_AND_UPLOAD_MAX_SIZE=50M
# PHP runtime tuning (K2, H4)
ENV PHP_OPCACHE_MEMORY=192 \
    PHP_OPCACHE_MAX_FILES=50000 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 \
    PHP_OPCACHE_REVALIDATE_FREQ=60 \
    PHP_MYSQLND_NET_READ_TIMEOUT=300

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# packages.sury.org: signing key pinned by fingerprint, repository bound to that key only
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg && \
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/deb.sury.org-php.gpg && \
    gpg --show-keys --with-fingerprint /usr/share/keyrings/deb.sury.org-php.gpg | tr -d ' ' | grep -q "^${SURY_REPO_FINGERPRINT}$" \
        || { echo "unexpected packages.sury.org key fingerprint"; exit 1; } && \
    echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ trixie main" > /etc/apt/sources.list.d/php.list && \
    rm -rf /var/lib/apt/lists/*

# Apache, PHP 7.4 (mod_php + CLI) with the extension set of the previous php7.4-apache image, plus tooling
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apache2 \
        libapache2-mod-php7.4 \
        php7.4-cli \
        php7.4-bcmath \
        php7.4-curl \
        php7.4-gd \
        php7.4-intl \
        php7.4-json \
        php7.4-ldap \
        php7.4-mbstring \
        php7.4-mysql \
        php7.4-opcache \
        php7.4-readline \
        php7.4-redis \
        php7.4-soap \
        php7.4-xml \
        php7.4-xsl \
        php7.4-zip \
        locales \
        git \
        ssh-client \
        wget \
        jq \
        msmtp \
        sudo \
        vim \
        unzip \
        graphicsmagick \
        ghostscript \
        lsb-release \
        mailutils && \
    rm -rf /var/lib/apt/lists/*

# Build-time guard: the installed package revision has to contain the CVE-2026-109618/109619 backport
RUN v="$(dpkg-query -W -f='${Version}' php7.4-cli)" && \
    { dpkg --compare-versions "$v" ge "$PHP_MIN_PACKAGE_VERSION" || { echo "php7.4-cli $v is older than $PHP_MIN_PACKAGE_VERSION"; exit 1; }; } && \
    echo "php7.4-cli $v"

COPY ./config/php.ini /etc/php/7.4/mods-available/zz-propeller.ini
COPY ./config/000-default.conf /etc/apache2/sites-available/000-default.conf
COPY ./config/apache2.conf /etc/apache2/apache2.conf
COPY ./config/mpm_prefork.conf /etc/apache2/mods-available/mpm_prefork.conf
COPY ./config/locale.gen /etc/locale.gen

COPY ./scripts/*.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

RUN mkdir -p /home/propeller/.composer/cache && chown -R propeller:propeller /home/propeller/ && chmod -R 0750 /home/propeller/

# Apache: Debian's envvars become overridable defaults (same approach as the official php images), prefork
# with mod_php, the module set of the previous image, no cgi-bin and no second access log (H5).
# The propeller ini is the last drop-in for both SAPIs.
RUN sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' /etc/apache2/envvars && \
    (a2dismod -q mpm_event || true) && \
    a2enmod -q mpm_prefork php7.4 rewrite deflate headers mime expires filter setenvif env authz_core auth_basic alias && \
    (a2disconf -q serve-cgi-bin other-vhosts-access-log || true) && \
    rm -f /etc/apache2/conf-enabled/serve-cgi-bin.conf /etc/apache2/conf-enabled/other-vhosts-access-log.conf && \
    rm -rf /var/www/html/* && \
    mkdir -p "$APACHE_LOCK_DIR" "$APACHE_RUN_DIR" "$APACHE_LOG_DIR" && \
    chown "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$APACHE_LOCK_DIR" "$APACHE_RUN_DIR" "$APACHE_LOG_DIR" && \
    ln -s /etc/php/7.4/mods-available/zz-propeller.ini /etc/php/7.4/apache2/conf.d/99-zz-propeller.ini && \
    ln -s /etc/php/7.4/mods-available/zz-propeller.ini /etc/php/7.4/cli/conf.d/99-zz-propeller.ini

# Add propeller Gitlab to known hosts for composer (non-fatal: hosts are unreachable from public CI runners)
RUN (ssh-keyscan -T 5 -H gitlab.propeller.de atum.propeller.de >> /etc/ssh/ssh_known_hosts || true)

# Generate and set Locale
RUN locale-gen
ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
# Set Timezone
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Static health endpoint for Kubernetes probes (H3) and drop-in directory for per-site Apache rules (K2)
RUN mkdir -p /opt/propeller/healthz /etc/apache2/site.d && echo ok > /opt/propeller/healthz/index.html

# Validate the complete configuration at build time without starting a daemon (H6)
RUN APACHE_MAX_REQUEST_WORKERS=8 apache2ctl -t

# Every extension of the previous image has to load, and the propeller ini must be active for the CLI as well
RUN php -v | grep -q '^PHP 7\.4\.' && \
    for ext in bcmath curl gd intl json ldap mbstring mysqli pdo_mysql redis soap sockets sysvmsg sysvsem xsl zip; do \
        php -m | grep -qix "$ext" || { echo "extension $ext failed to load"; exit 1; }; \
    done && \
    php -m | grep -qi opcache && \
    php --ini | grep -q 99-zz-propeller.ini

EXPOSE $PORT

ENTRYPOINT ["entrypoint.sh"]
