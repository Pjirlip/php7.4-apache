# PHP-FPM container for legacy PHP 7.4 sites: runs PHP only. The Apache container is the shared
# ghcr.io/pjirlip/httpd image (event MPM + mod_proxy_fcgi), which proxies .php requests to this container
# over 127.0.0.1:9000 inside the same pod.
#
# PHP 7.4 is end-of-life upstream: no official php:7.4 image carries the fixes for CVE-2026-109618/109619.
# Ondřej Surý's Debian packages do (7.4.33-31 of 21 Oct 2026, 160+ backports), so PHP comes from
# packages.sury.org instead of an unpatched upstream tarball. Rebuilding picks up newer revisions.
FROM debian:trixie-slim
LABEL maintainer="Philipp Dippel <philipp.dippel@propeller.de>"
SHELL ["/bin/bash", "-c"]

ARG SURY_REPO_FINGERPRINT=15058500A0235D97F5D10063B188E2B695BD4743
ARG PHP_MIN_PACKAGE_VERSION=1:7.4.33-31

# groupadd/useradd from the essential passwd package: trixie-slim has no adduser wrapper
RUN groupadd --gid 1000 propeller && useradd --system --uid 1000 --gid propeller propeller

ENV PROVISION_CONTEXT="production"
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Berlin
ENV DOCUMENT_ROOT=/var/www/html
ENV LETSENCRYPT_EMAIL=certbot@propeller.de
# Debian packaging layout: php.ini per SAPI below this directory, shared drop-ins in mods-available;
# entrypoint.sh writes the pool for php-fpm7.4 into pool.d
ENV PHP_INI_DIR=/etc/php/7.4 \
    FPM_BIN=php-fpm7.4 \
    FPM_POOL_FILE=/etc/php/7.4/fpm/pool.d/zz-propeller.conf
# Pool sizing (K1). An empty PHP_FPM_MAX_CHILDREN lets entrypoint.sh derive the value from the container
# memory limit: floor((limit_MiB - BASELINE_MB) / CHILD_MB). Only PHP requests occupy a child.
ENV PHP_FPM_LISTEN=127.0.0.1:9000 \
    PHP_FPM_PM=dynamic \
    PHP_FPM_MAX_CHILDREN="" \
    PHP_FPM_CHILD_MEMORY_MB=64 \
    PHP_FPM_BASELINE_MEMORY_MB=256 \
    PHP_FPM_START_SERVERS=2 \
    PHP_FPM_MIN_SPARE_SERVERS=1 \
    PHP_FPM_MAX_SPARE_SERVERS=4 \
    PHP_FPM_PROCESS_IDLE_TIMEOUT=10s \
    PHP_FPM_MAX_REQUESTS=1000 \
    PHP_FPM_REQUEST_TERMINATE_TIMEOUT=300 \
    PHP_FPM_SLOWLOG_TIMEOUT=0

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

# PHP 7.4 FPM + CLI with the extension set of the previous php7.4-apache image, plus tooling
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        php7.4-fpm \
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
COPY ./config/php-fpm.conf /etc/php/7.4/fpm/php-fpm.conf
COPY ./config/locale.gen /etc/locale.gen
COPY ./scripts/entrypoint.sh ./scripts/typo3_form_cleanup.sh /usr/local/bin/

# propeller ini as the last drop-in for FPM and CLI; the package's default pool is replaced by the one
# entrypoint.sh writes at startup
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/typo3_form_cleanup.sh && \
    rm -f /etc/php/7.4/fpm/pool.d/*.conf && \
    ln -s /etc/php/7.4/mods-available/zz-propeller.ini /etc/php/7.4/fpm/conf.d/99-zz-propeller.ini && \
    ln -s /etc/php/7.4/mods-available/zz-propeller.ini /etc/php/7.4/cli/conf.d/99-zz-propeller.ini && \
    mkdir -p /run/php

RUN mkdir -p /home/propeller/.composer/cache && chown -R propeller:propeller /home/propeller/ && chmod -R 0750 /home/propeller/

# Add propeller Gitlab to known hosts for composer (non-fatal: hosts are unreachable from public CI runners)
RUN (ssh-keyscan -T 5 -H gitlab.propeller.de atum.propeller.de >> /etc/ssh/ssh_known_hosts || true)

# Generate and set Locale; verified because locale-gen silently skips a last line without newline
RUN locale-gen && locale -a | grep -qi "^en_US.utf8$"
ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
# Set Timezone
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Validate pool generation and the complete FPM configuration at build time (H6); PHP 7.4 and every
# extension of the previous image have to load, the propeller ini must be active for FPM and CLI
RUN PHP_FPM_MAX_CHILDREN=4 entrypoint.sh php-fpm7.4 -t && \
    php -v | grep -q '^PHP 7\.4\.' && \
    for ext in bcmath curl gd intl json ldap mbstring mysqli pdo_mysql redis soap sockets sysvmsg sysvsem xsl zip; do \
        php -m | grep -qix "$ext" || { echo "extension $ext failed to load"; exit 1; }; \
    done && \
    php -m | grep -qi opcache && \
    php --ini | grep -q 99-zz-propeller.ini && \
    ls -l /etc/php/7.4/fpm/conf.d/99-zz-propeller.ini

EXPOSE 9000

# SIGQUIT is php-fpm's graceful stop; Kubernetes sends it on pod termination (bounded by process_control_timeout)
STOPSIGNAL SIGQUIT

ENTRYPOINT ["entrypoint.sh"]
CMD ["php-fpm7.4"]
