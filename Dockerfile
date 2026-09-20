# ==============================================
# MULTI-STAGE BASE IMAGES
# ==============================================
FROM envoyproxy/envoy:v1.39.1 AS envoy
FROM ghcr.io/xtls/xray-core:25.12.8 AS xray
FROM openresty/openresty:1.31.1.1-bookworm-fat

ENV DEBIAN_FRONTEND=noninteractive

# ==============================================
# PORT CONFIG — TUGMA SA CLOUD RUN & IYONG STACK
# ==============================================
ENV PORT="${PORT:-8080}"
ENV BIND_ADDR="${BIND_ADDR:-0.0.0.0}"

ENV XRAY_LOCATION_ASSET="/usr/local/share/xray"
ENV XRAY_LOCATION_CONFIG="/etc/xray"

ENV HAPROXY_PORT="${HAPROXY_PORT:-8081}"
ENV OPENRESTY_PORT="${OPENRESTY_PORT:-8080}" # ✅ INAYOS: Gawing 8080 PARA CLOUD RUN
ENV APACHE_PORT="${APACHE_PORT:-8083}"

ENV HAPROXY_GRPC_PORT="${HAPROXY_GRPC_PORT:-8084}"
ENV OPENRESTY_GRPC_PORT="${OPENRESTY_GRPC_PORT:-8085}"

WORKDIR /opt/virgozki

# ==============================================
# INSTALL DEPENDENCIES & PREPARE ENV
# ==============================================
RUN apt-get update && apt-get upgrade -y && \
apt-get install -y --no-install-recommends \
apache2 \
apache2-utils \
haproxy \
ca-certificates \
curl \
wget \
unzip \
tini \
procps \
iproute2 \
net-tools \
openssl && \
# ✅ ENABLE APACHE MODULES
a2enmod proxy proxy_http proxy_wstunnel headers rewrite http2 ssl && \
# ✅ DISABLE DEFAULT APACHE PARA WALANG CONFLICT
a2dissite 000-default && \
# ✅ CREATE MISSING DIRECTORIES
mkdir -p \
/etc/xray \
/etc/haproxy \
/etc/envoy \
/etc/apache2/conf-available \
/etc/apache2/conf-enabled \
/tmp/virgozki \
/tmp/virgozki-logs \
/usr/share/nginx/html \
/usr/local/share/xray \
/var/run/apache2 \
/run/haproxy \
/var/log/xray \
/var/log/apache2 && \
rm -rf /var/lib/apt/lists/*

# ==============================================
# COPY BINARIES FROM OTHER STAGES
# ==============================================
COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=xray /usr/local/share/xray/. /usr/local/share/xray/

# ==============================================
# COPY CONFIG & FILES — TAMA NA PATH LAHAT
# ==============================================
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/openresty/nginx.conf
COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY httpd.conf /etc/apache2/conf-available/virgozki.conf
COPY index.html /usr/share/nginx/html/index.html
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# ==============================================
# FINAL PERMISSIONS & SETUP
# ==============================================
RUN a2enconf virgozki && \
chmod +x /usr/local/bin/entrypoint.sh && \
chown -R www-data:www-data /usr/share/nginx/html /var/log/apache2 /var/run/apache2

# ✅ I-EXPOSE LAHAT NG GINAGAMIT NA PORT
EXPOSE 8080 8081 8083 8085

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
