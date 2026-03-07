ARG VERSION_PHP=8.3
ARG VERSION_COMPOSER=lts

FROM composer:${VERSION_COMPOSER} AS comp
FROM php:${VERSION_PHP}-apache AS builder

# Copy composer
COPY --from=comp /usr/bin/composer /usr/bin/composer

# Update and install required debian packages
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008 # 'Pin versions in apt get install'
RUN <<EORUN
set -xeu
apt-get update
apt-get upgrade --yes
apt-get install --yes --no-install-recommends \
  git \
  libjpeg-dev \
  libldap-dev \
  libpng-dev \
  libfreetype6-dev \
  unzip
EORUN

# Customize the http & php environment
RUN <<EORUN
set -xeu
cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
cat > /etc/apache2/conf-available/remoteip.conf <<EOF
RemoteIPHeader X-Real-IP
RemoteIPInternalProxy 10.0.0.0/8
RemoteIPInternalProxy 172.16.0.0/12
RemoteIPInternalProxy 192.168.0.0/16
EOF
a2enconf remoteip
a2enmod rewrite
a2enmod headers
a2enmod remoteip
docker-php-ext-configure gd --with-jpeg --with-freetype
docker-php-ext-install mysqli gd ldap
pecl install timezonedb
docker-php-ext-enable timezonedb
mkdir --parent /var/log/librebooking
chown --recursive www-data:root /var/log/librebooking
chmod --recursive g+rwx /var/log/librebooking
touch /usr/local/etc/php/conf.d/librebooking.ini
sed \
  -i /etc/apache2/ports.conf \
  -e 's/Listen 80/Listen 8080/' \
  -e 's/Listen 443/Listen 8443/'
sed \
  -i /etc/apache2/sites-available/000-default.conf \
  -e 's/<VirtualHost *:80>/<VirtualHost *:8080>/'
EORUN
# Get and customize librebooking
ARG APP_GH_REF
ARG APP_GH_ADD_SHA=false
RUN <<EORUN

set -xeu

mkdir -p /build/html
cd /build/html
git clone https://github.com/LibreBooking/librebooking.git -b develop .
git reset --hard ${APP_GH_REF}
if [ "${APP_GH_ADD_SHA}" == "true" ]; then
  echo "${APP_GH_ADD_SHA:0:6}" > config/version-suffix.txt
fi
rm -rf .git

if [ -f composer.json ]; then
  sed \
    -i composer.json \
    -e "s:\(.*\)nickdnk/graph-sdk\(.*\)7.0\(.*\):\1joelbutcher/facebook-graph-sdk\26.1\3:"
  composer install
fi
sed \
  -i database_schema/create-user.sql \
  -e "s:^DROP USER ':DROP USER IF EXISTS ':g" \
  -e "s:booked_user:schedule_user:g" \
  -e "s:localhost:%:g"
if ! [ -d tpl_c ]; then
  mkdir tpl_c
fi
mkdir Web/uploads/reservation
EORUN

FROM php:${VERSION_PHP}-apache

# Labels
LABEL org.opencontainers.image.title="LibreBooking"
LABEL org.opencontainers.image.description="LibreBooking as a container"
LABEL org.opencontainers.image.url="https://github.com/librebooking/docker"
LABEL org.opencontainers.image.source="https://github.com/librebooking/docker"
LABEL org.opencontainers.image.licenses="GPL-3.0"
LABEL org.opencontainers.image.authors="colisee@hotmail.com"

# Copy entrypoint scripts
COPY --chmod=755 bin /usr/local/bin/

# Create cron jobs
COPY --chown=www-data:www-data --chmod=0755 lb-jobs-cron /config/

# Latest releases available at https://github.com/aptible/supercronic/releases
ENV SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.43/supercronic-linux-amd64 \
    SUPERCRONIC_SHA1SUM=f97b92132b61a8f827c3faf67106dc0e4467ccf2 \
    SUPERCRONIC=supercronic-linux-amd64

RUN curl -fsSLO "$SUPERCRONIC_URL" \
 && echo "${SUPERCRONIC_SHA1SUM}  ${SUPERCRONIC}" | sha1sum -c - \
 && chmod +x "$SUPERCRONIC" \
 && mv "$SUPERCRONIC" "/usr/local/bin/${SUPERCRONIC}" \
 && ln -s "/usr/local/bin/${SUPERCRONIC}" /usr/local/bin/supercronic

# Update and install required debian packages
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008 # 'Pin versions in apt get install'
RUN <<EORUN
set -xeu
apt-get update
apt-get upgrade --yes
apt-get install --yes --no-install-recommends \
  git \
  libjpeg-dev \
  libldap-dev \
  libpng-dev \
  libfreetype6-dev \
  unzip
EORUN

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Customize the http & php environment
RUN <<EORUN
set -xeu
cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
cat > /etc/apache2/conf-available/remoteip.conf <<EOF
RemoteIPHeader X-Real-IP
RemoteIPInternalProxy 10.0.0.0/8
RemoteIPInternalProxy 172.16.0.0/12
RemoteIPInternalProxy 192.168.0.0/16
EOF
a2enconf remoteip
a2enmod rewrite
a2enmod headers
a2enmod remoteip
docker-php-ext-configure gd --with-jpeg --with-freetype
docker-php-ext-install mysqli gd ldap
pecl install timezonedb
docker-php-ext-enable timezonedb
mkdir --parent /var/log/librebooking
chown --recursive www-data:root /var/log/librebooking
chmod --recursive g+rwx /var/log/librebooking
touch /usr/local/etc/php/conf.d/librebooking.ini
sed \
  -i /etc/apache2/ports.conf \
  -e 's/Listen 80/Listen 8080/' \
  -e 's/Listen 443/Listen 8443/'
sed \
  -i /etc/apache2/sites-available/000-default.conf \
  -e 's/<VirtualHost *:80>/<VirtualHost *:8080>/'
EORUN

# Copy LB install dir
COPY --from=builder /build/html /var/www/html

RUN <<EORUN
set -xeu
chown www-data:root \
  /var/www/html/config \
  /var/www/html/tpl_c \
  /var/www/html/Web/uploads/images \
  /var/www/html/Web/uploads/reservation \
  /usr/local/etc/php/conf.d/librebooking.ini
chmod g+rwx \
  /var/www/html/config \
  /var/www/html/tpl_c \
  /var/www/html/Web/uploads/images \
  /var/www/html/Web/uploads/reservation \
  /usr/local/etc/php/conf.d/librebooking.ini
chown --recursive www-data:root \
  /var/www/html/plugins
chmod --recursive g+rwx \
  /var/www/html/plugins
EORUN

# Environment
USER       www-data
WORKDIR    /
VOLUME     /config
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD        ["apache2-foreground"]
EXPOSE     8080
