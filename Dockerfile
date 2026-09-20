# ============================================================
# VIRGOZKI 4-PROXY + gRPC | CLOUD RUN | DEBIAN BOOKWORM
# Envoy -> HAProxy -> OpenResty -> Apache -> Xray
# ============================================================

FROM envoyproxy/envoy:v1.39.1 AS envoy
FROM ghcr.io/xtls/xray-core:25.12.8 AS xray
FROM openresty/openresty:1.31.1.1-bookworm-fat

# ============================================================
# GLOBAL ENV VARS (MATCHES ALL YOUR CONFIGS)
# ============================================================
ENV DEBIAN_FRONTEND=noninteractive

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
# SYSTEM & DEPENDENCIES
# ============================================================
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
    # ✅ FIX: Create required system users
    && groupadd -r haproxy && useradd -r -g haproxy -d /var/lib/haproxy -s /usr/sbin/nologin haproxy \
    # ✅ Enable Apache modules
    && a2enmod \
        proxy \
        proxy_http \
        proxy_http2 \
        proxy_wstunnel \
        headers \
        rewrite \
        http2 \
    # ✅ Cleanup
    && rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/*

# ============================================================
# BINARIES FROM OFFICIAL IMAGES
# ============================================================
COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=xray /usr/local/share/xray /usr/local/share/xray

# ============================================================
# DIRECTORIES & PERMISSIONS
# ============================================================
RUN mkdir -p \
        /etc/xray \
        /etc/haproxy \
        /etc/apache2/conf-available \
        /etc/apache2/conf-enabled \
        /var/log/xray \
        /var/log/apache2 \
        /var/lock/apache2 \
        /var/run/apache2 \
        /var/run/haproxy \
        /var/lib/haproxy \
        /tmp/virgozki-logs \
        /tmp/virgozki \
    && chmod 777 \
        /tmp \
        /run \
        /var/run \
        /var/log \
        /var/lock/apache2 \
        /var/run/apache2 \
        /var/run/haproxy \
        /var/lib/haproxy \
        /tmp/virgozki-logs \
        /tmp/virgozki \
    && chown -R haproxy:haproxy /var/lib/haproxy /var/run/haproxy

# ============================================================
# CONFIG FILES
# ============================================================
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/openresty/nginx.conf
COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY httpd.conf /etc/apache2/conf-available/virgozki.conf

RUN a2enconf virgozki

COPY index.html /usr/share/nginx/html/index.html
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# ============================================================
# FINAL PERMISSIONS
# ============================================================
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && chmod 644 \
        /etc/xray/config.json \
        /etc/openresty/nginx.conf \
        /etc/haproxy/haproxy.cfg \
        /etc/apache2/conf-available/virgozki.conf \
    && chmod -R 755 /usr/share/nginx/html

# ============================================================
# CLOUD RUN REQUIRED
# ============================================================
EXPOSE 8080

# ============================================================
# ENTRYPOINT
# ============================================================
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
