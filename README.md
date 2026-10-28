# php7.4-apache

> **Branch `fpm`:** dieses Repository baut hier das PHP-FPM-Image `ghcr.io/pjirlip/php7.4-fpm` (`Dockerfile`,
> `php7.4-fpm` aus packages.sury.org, Pool unter `/etc/php/7.4/fpm/pool.d/`). Der Apache-Container ist für alle
> PHP-Versionen derselbe, `ghcr.io/pjirlip/httpd` aus dem Repository `php8.2` (event-MPM + mod_proxy_fcgi, ohne
> PHP). Aufbau, Pool-Dimensionierung, Probes und Deployment-Skelett sind im README von `php8.2` (Abschnitt
> "Apache + PHP-FPM") beschrieben. `php7.4-apache:latest` bleibt bis zum Merge unverändert.

Dockerimage für Hosting von Legacy-Seiten mit PHP 7.4 (Apache prefork + mod_php), gleiche Konfiguration,
gleiche Umgebungsvariablen und gleiches Betriebsmodell wie `php8.2-apache`.

Inkl. GM und Redis Support. Siehe `.env.sample` für Konfigurationsmöglichkeiten.

## Woher kommt PHP 7.4 mit Sicherheitsfixes?

PHP 7.4 ist seit November 2022 End-of-Life. Die offiziellen `php:7.4`-Images enden bei 7.4.33, und für
CVE-2026-109618 / CVE-2026-109619 (CERT-EU 2026-018) gibt es keinen Upstream-Release mehr.

Dieses Image baut PHP deshalb **nicht** aus dem ungepatchten Upstream-Tarball, sondern installiert die
Debian-Pakete von Ondřej Surý (`packages.sury.org`, Suite `trixie`). Das Paket `php7.4 1:7.4.33-31`
vom 21. Oktober 2026 enthält den Backport "Avoid state corruption via bailout" für die beiden CVEs
sowie die Backports aller vorherigen Advisories seit 7.4.33 (über 160 Patches, inklusive OpenSSL-3-Anpassung
für aktuelle Debian-Versionen).

Absicherung im Build:

- Der Repository-Schlüssel wird gegen den Fingerprint `1505 8500 A023 5D97 F5D1 0063 B188 E2B6 95BD 4743`
  geprüft, das Repository ist ausschließlich an diesen Schlüssel gebunden (`signed-by`).
- Der Build bricht ab, wenn die installierte Paketrevision älter als `1:7.4.33-31` ist
  (`PHP_MIN_PACKAGE_VERSION`), bei künftigen Fixes den Wert anheben.
- `php -v`, alle Extensions des bisherigen Images, `apache2ctl -t` und die aktive propeller-ini werden geprüft.

Ein Rebuild (`workflow_dispatch` oder Push) zieht automatisch die neueste Paketrevision und die Debian-Updates
für Apache, OpenSSL und Co.

## Unterschiede zu den php8.x-Images

| Thema | php8.x-apache | php7.4-apache |
|-------|---------------|---------------|
| Basis | `php:8.x-apache` (Docker Library) | `debian:trixie-slim` + `packages.sury.org` |
| PHP-Installation | aus dem Quelltext im Basis-Image | Debian-Pakete `php7.4-*` |
| Extensions | `docker-php-ext-install`, `pecl` | `apt-get install php7.4-<ext>` |
| php.ini | `/usr/local/etc/php/php.ini` + `conf.d/zz-propeller.ini` | `/etc/php/7.4/{apache2,cli}/php.ini` + `conf.d/99-zz-propeller.ini` (Symlink auf `mods-available/zz-propeller.ini`) |
| mod_php | vom Basis-Image | `libapache2-mod-php7.4`, geladen über `mods-enabled/php7.4.load` |

Für Deployments ist das unsichtbar: Port 80, `DOCUMENT_ROOT`, Healthz unter `/healthz`, Worker-Berechnung aus
dem Memory-Limit, Logs auf stdout/stderr, Entrypoint und Signalbehandlung sind identisch.

Extensions: bcmath, curl, gd, intl, json, ldap, mbstring, mysqli/pdo_mysql, opcache, readline, redis, soap,
sockets, sysvmsg/sysvsem, xml/dom/simplexml, xsl, zip. Zusätzlich GraphicsMagick, Ghostscript, Composer 2,
msmtp, git, ssh-client.

## Kubernetes

Deployment-Anforderungen, Probes und Worker-Formel wie bei `php8.2-apache` (siehe dortiges README):
`limits.memory` setzen, `terminationGracePeriodSeconds: 45`, `/tmp` als emptyDir, Probes auf `/healthz`.

Beispiel-CronJobs unter `cron-jobs/`:

- `typo3-scheduler.yaml`: Scheduler alle 15 Minuten über `typo3/sysext/core/bin/typo3 scheduler:run`
  (Legacy-Installation ohne Composer; im Composer-Modus `vendor/bin/typo3` und `DOCUMENT_ROOT=.../public`).
- `typo3-form-cleanup.yaml`: tägliche Bereinigung von `form_*`-Upload-Verzeichnissen unter `fileadmin/user_upload`.

`TYPO3_SCHEDULER` und `METRICS_PASSWORD` aus dem alten Image haben keine Wirkung mehr: kein Cron und kein
goaccess im Container, Auswertung der Zugriffe läuft über Traefik/Umami.

## Umgebungsvariablen

Identisch mit `php8.2-apache`: `APACHE_MAX_REQUEST_WORKERS`, `APACHE_CHILD_MEMORY_MB`,
`APACHE_BASELINE_MEMORY_MB`, `APACHE_MIN_SPARE_SERVERS`, `APACHE_MAX_SPARE_SERVERS`,
`APACHE_MAX_CONNECTIONS_PER_CHILD`, `APACHE_TIMEOUT`, `APACHE_ALLOW_OVERRIDE`, `PHP_OPCACHE_MEMORY`,
`PHP_OPCACHE_MAX_FILES`, `PHP_OPCACHE_VALIDATE_TIMESTAMPS`, `PHP_OPCACHE_REVALIDATE_FREQ`,
`PHP_MYSQLND_NET_READ_TIMEOUT` sowie `PHP_MEMORY_LIMIT`, `PHP_MAX_EXEC_TIME`, `PHP_POST_AND_UPLOAD_MAX_SIZE`,
`SMTP_*`, `DOCUMENT_ROOT`, `TZ`.

## Build über GitHub Actions

`.github/workflows/docker-build.yml` baut das Image auf jedem Push und veröffentlicht es nach
`ghcr.io/<owner>/<repo>`, Tags wie bei den anderen Images (`latest` vom Default-Branch, `sha-<short>`,
`production` über Release-Tag oder manuellen Lauf).

Lokal testen:

```sh
docker build -t php7.4-propeller-apache .
docker run --rm php7.4-propeller-apache php -v
docker run --rm php7.4-propeller-apache dpkg-query -W php7.4-cli
```
