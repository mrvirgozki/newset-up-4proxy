# ============================================================
# VIRGOZKI 4-PROXY + gRPC | CLOUD RUN | DEBIAN BOOKWORM
# Envoy -> HAProxy -> OpenResty -> Apache -> Xray
# ============================================================

# ------------------------------------------------------------
# ENVOY
# ------------------------------------------------------------
FROM envoyproxy/envoy:v1.39.1 AS envoy

# ------------------------------------------------------------
# XRAY
# ------------------------------------------------------------
FROM ghcr.io/xtls/xray-core:25.12.8 AS xray

# ------------------------------------------------------------
# MAIN IMAGE
# ------------------------------------------------------------
FROM openresty/openresty:1.31.1.1-bookworm-fat

ENV DEBIAN_FRONTEND=noninteractive

# ============================================================
# ENVIRONMENT
# ============================================================

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray
ENV XRAY_LOCATION_CONFIG=/etc/xray

ENV BIND_ADDR=0.0.0.0
ENV PORT=8080

ENV HAPROXY_PORT=8081
ENV OPENRESTY_PORT=8082
ENV APACHE_PORT=8083

ENV HAPROXY_GRPC_PORT=8084
ENV OPENRESTY_GRPC_PORT=8085

WORKDIR /opt/virgozki

# ============================================================
# INSTALL PACKAGES
# ============================================================

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
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
        openssl && \
    a2enmod \
        proxy \
        proxy_http \
        proxy_http2 \
        proxy_wstunnel \
        headers \
        rewrite \
        http2 || true && \
    mkdir -p \
        /var/lib/haproxy \
        /run/haproxy \
        /var/run/haproxy \
        /run/apache2 \
        /var/run/apache2 \
        /etc/xray \
        /etc/haproxy \
        /etc/envoy \
        /tmp/virgozki \
        /tmp/virgozki-logs \
        /var/log/xray && \
    chown -R haproxy:haproxy \
        /var/lib/haproxy \
        /run/haproxy \
        /var/run/haproxy && \
    chmod 777 \
        /tmp/virgozki \
        /tmp/virgozki-logs \
        /run/apache2 \
        /var/run/apache2 \
        /var/run/haproxy && \
    rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/*

# ============================================================
# COPY ENVOY
# ============================================================

COPY --from=envoy \
    /usr/local/bin/envoy \
    /usr/local/bin/envoy

# ============================================================
# COPY XRAY
# ============================================================

COPY --from=xray \
    /usr/local/bin/xray \
    /usr/local/bin/xray

COPY --from=xray \
    /usr/local/share/xray \
    /usr/local/share/xray

# ============================================================
# CONFIG DIRECTORIES
# ============================================================

RUN mkdir -p \
        /etc/xray \
        /etc/haproxy \
        /etc/envoy \
        /etc/apache2/conf-available \
        /etc/apache2/conf-enabled \
        /var/log/xray \
        /var/log/apache2 \
        /var/lock/apache2 \
        /var/run/apache2 \
        /tmp/virgozki \
        /tmp/virgozki-logs && \
    chmod 755 \
        /etc/xray \
        /etc/haproxy \
        /etc/envoy

# ============================================================
# CONFIGURATION FILES
# ============================================================

COPY config.json \
    /etc/xray/config.json

COPY nginx.conf \
    /etc/openresty/nginx.conf

COPY haproxy.cfg \
    /etc/haproxy/haproxy.cfg

COPY httpd.conf \
    /etc/apache2/conf-available/virgozki.conf

COPY index.html \
    /usr/share/nginx/html/index.html

COPY entrypoint.sh \
    /usr/local/bin/entrypoint.sh

# ============================================================
# ENABLE APACHE CONFIG
# ============================================================

RUN a2enconf virgozki || true

# ============================================================
# PERMISSIONS
# ============================================================

RUN chmod +x \
        /usr/local/bin/entrypoint.sh && \
    chmod 644 \
        /etc/xray/config.json \
        /etc/openresty/nginx.conf \
        /etc/haproxy/haproxy.cfg \
        /etc/apache2/conf-available/virgozki.conf && \
    chmod -R 755 \
        /usr/share/nginx/html

# ============================================================
# CLOUD RUN
# ============================================================

EXPOSE 8080

# ============================================================
# INIT
# ============================================================

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/usr/local/bin/entrypoint.sh"]
