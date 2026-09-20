# ============================================================
# VIRGOZKI 4-PROXY + gRPC
# Cloud Run / Debian Bookworm
# ============================================================

# ------------------------------------------------------------
# Envoy stage
# ------------------------------------------------------------
FROM envoyproxy/envoy:v1.39.1 AS envoy

# ------------------------------------------------------------
# Xray stage
# ------------------------------------------------------------
FROM ghcr.io/xtls/xray-core:25.12.8 AS xray

# ------------------------------------------------------------
# Main image
# ------------------------------------------------------------
FROM openresty/openresty:1.31.1.1-bookworm-fat

ENV DEBIAN_FRONTEND=noninteractive

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray
ENV XRAY_LOCATION_CONFIG=/etc/xray

WORKDIR /opt/virgozki

# ------------------------------------------------------------
# System packages + Apache modules
# ------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apache2 \
        apache2-utils \
        libapache2-mod-proxy-html \
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
    # Enable required Apache modules permanently
    a2enmod proxy proxy_http proxy_http2 proxy_wstunnel headers rewrite http2 && \
    # Cleanup
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ------------------------------------------------------------
# Copy Envoy
# ------------------------------------------------------------
COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy

# ------------------------------------------------------------
# Copy Xray
# ------------------------------------------------------------
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=xray /usr/local/share/xray /usr/local/share/xray

# ------------------------------------------------------------
# Directories & Permissions
# ------------------------------------------------------------
RUN mkdir -p \
        /etc/xray \
        /var/log/xray \
        /tmp/virgozki-logs \
        /tmp/virgozki \
        /run/apache2 \
        /var/run/apache2 \
        /var/run/haproxy && \
    chmod -R 777 /tmp /run /var/run && \
    chown -R www-data:www-data /usr/local/openresty/nginx/html

# ------------------------------------------------------------
# Configs
# ------------------------------------------------------------
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/openresty/nginx.conf
COPY index.html /usr/local/openresty/nginx/html/index.html
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# ------------------------------------------------------------
# Final Permissions
# ------------------------------------------------------------
RUN chmod +x /usr/local/bin/entrypoint.sh && \
    chmod 644 /etc/xray/config.json && \
    chmod 644 /etc/openresty/nginx.conf && \
    chmod 644 /usr/local/openresty/nginx/html/index.html

# ------------------------------------------------------------
# Cloud Run
# ------------------------------------------------------------
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
