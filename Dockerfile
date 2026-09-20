# ============================================================
# VIRGOZKI 4-PROXY + gRPC | CLOUD RUN | DEBIAN BOOKWORM
# Envoy -> HAProxy -> OpenResty -> Apache -> Xray
# ============================================================

# ------------------------------------------------------------
# ENVoy
# ------------------------------------------------------------
FROM envoyproxy/envoy:v1.39.1 AS envoy

# ------------------------------------------------------------
# XRAY
# ------------------------------------------------------------
FROM ghcr.io/xtls/xray-core:25.12.8 AS xray

# ------------------------------------------------------------
# BASE
# ------------------------------------------------------------
FROM openresty/openresty:1.31.1.1-bookworm-fat

ENV DEBIAN_FRONTEND=noninteractive

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray
ENV XRAY_LOCATION_CONFIG=/etc/xray

ENV BIND_ADDR=0.0.0.0
ENV PORT=8080

# Internal proxy ports
ENV HAPROXY_PORT=8081
ENV OPENRESTY_PORT=8082
ENV APACHE_PORT=8083

WORKDIR /opt/virgozki

# ------------------------------------------------------------
# INSTALL DEPENDENCIES
# ------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        apache2 \
        apache2-utils \
        haproxy \
        python3 \
        ca-certificates \
        curl \
        wget \
        unzip \
        tini \
        procps \
        iproute2 \
        net-tools \
        openssl \
    && a2enmod \
        proxy \
        proxy_http \
        proxy_http2 \
        proxy_wstunnel \
        headers \
        rewrite \
        http2 \
    && rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/*

# ------------------------------------------------------------
# COPY ENVOY
# ------------------------------------------------------------
COPY --from=envoy \
    /usr/local/bin/envoy \
    /usr/local/bin/envoy

# ------------------------------------------------------------
# COPY XRAY
# ------------------------------------------------------------
COPY --from=xray \
    /usr/local/bin/xray \
    /usr/local/bin/xray

COPY --from=xray \
    /usr/local/share/xray \
    /usr/local/share/xray

# ------------------------------------------------------------
# DIRECTORIES
# ------------------------------------------------------------
RUN mkdir -p \
        /etc/xray \
        /etc/haproxy \
        /etc/apache2/conf-available \
        /etc/apache2/conf-enabled \
        /var/log/xray \
        /tmp/virgozki-logs \
        /tmp/virgozki \
        /run/apache2 \
        /var/run/apache2 \
        /var/run/haproxy \
    && chmod 777 \
        /tmp \
        /run \
        /var/run \
        /tmp/virgozki-logs \
        /tmp/virgozki

# ------------------------------------------------------------
# XRAY
# ------------------------------------------------------------
COPY config.json \
    /etc/xray/config.json

# ------------------------------------------------------------
# OPENRESTY
# ------------------------------------------------------------
COPY nginx.conf \
    /etc/openresty/nginx.conf

# ------------------------------------------------------------
# HAPROXY
# ------------------------------------------------------------
COPY haproxy.cfg \
    /etc/haproxy/haproxy.cfg

# ------------------------------------------------------------
# APACHE
#
# IMPORTANT:
# This is loaded as an Apache conf file.
# It does NOT replace apache2.conf.
# ------------------------------------------------------------
COPY httpd.conf \
    /etc/apache2/conf-available/virgozki.conf

RUN a2enconf virgozki

# ------------------------------------------------------------
# PANEL
# ------------------------------------------------------------
COPY index.html \
    /usr/share/nginx/html/index.html

# ------------------------------------------------------------
# ENTRYPOINT
# ------------------------------------------------------------
COPY entrypoint.sh \
    /usr/local/bin/entrypoint.sh

# ------------------------------------------------------------
# PERMISSIONS
# ------------------------------------------------------------
RUN chmod +x \
        /usr/local/bin/entrypoint.sh \
    && chmod 644 \
        /etc/xray/config.json \
        /etc/openresty/nginx.conf \
        /etc/haproxy/haproxy.cfg \
        /etc/apache2/conf-available/virgozki.conf \
    && chmod -R 755 \
        /usr/share/nginx/html

# ------------------------------------------------------------
# CLOUD RUN
# ------------------------------------------------------------
EXPOSE 8080

# ------------------------------------------------------------
# TINI
# ------------------------------------------------------------
ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/usr/local/bin/entrypoint.sh"]
