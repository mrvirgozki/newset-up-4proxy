FROM envoyproxy/envoy:v1.39.1 AS envoy
FROM ghcr.io/xtls/xray-core:25.12.8 AS xray
FROM openresty/openresty:1.31.1.1-bookworm-fat

ENV DEBIAN_FRONTEND=noninteractive

# ✅ Dagdag: Required variables (tugma sa script at Cloud Run)
ENV PORT="${PORT:-8080}"
ENV BIND_ADDR="${BIND_ADDR:-0.0.0.0}"

ENV XRAY_LOCATION_ASSET="/usr/local/share/xray"
ENV XRAY_LOCATION_CONFIG="/etc/xray"

ENV HAPROXY_PORT="${HAPROXY_PORT:-8081}"
ENV OPENRESTY_PORT="${OPENRESTY_PORT:-8082}"
ENV APACHE_PORT="${APACHE_PORT:-8083}"

ENV HAPROXY_GRPC_PORT="${HAPROXY_GRPC_PORT:-8084}"
ENV OPENRESTY_GRPC_PORT="${OPENRESTY_GRPC_PORT:-8085}"

WORKDIR /opt/virgozki

RUN apt-get update && \
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
a2enmod \
proxy \
proxy_http \
proxy_wstunnel \
headers \
rewrite \
http2 && \
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

# ✅ Copy binaries + assets
COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=xray /usr/local/share/xray/. /usr/local/share/xray/

# ✅ Copy config files (tugma sa path)
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/openresty/nginx.conf
COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY httpd.conf /etc/apache2/conf-available/virgozki.conf
COPY index.html /usr/share/nginx/html/index.html
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN a2enconf virgozki && \
chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
