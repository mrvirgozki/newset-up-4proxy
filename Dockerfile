# ============================================================
# VIRGOZKI 4-PROXY + gRPC
# Cloud Run / Debian Bookworm
# ============================================================

# ------------------------------------------------------------
# ENVoy stage
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
# System packages
# ------------------------------------------------------------
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
    rm -rf /var/lib/apt/lists/*

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
# Xray configuration
# ------------------------------------------------------------
RUN mkdir -p \
        /etc/xray \
        /var/log/xray \
        /tmp/virgozki-logs \
        /tmp/virgozki

COPY config.json /etc/xray/config.json

# ------------------------------------------------------------
# OpenResty configuration
# ------------------------------------------------------------
COPY nginx.conf /etc/openresty/nginx.conf

# ------------------------------------------------------------
# Panel
# ------------------------------------------------------------
RUN mkdir -p /usr/local/openresty/nginx/html

COPY index.html /usr/local/openresty/nginx/html/index.html

# ------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh && \
    chmod 644 /etc/xray/config.json && \
    chmod 644 /etc/openresty/nginx.conf && \
    chmod 644 /usr/local/openresty/nginx/html/index.html

# ------------------------------------------------------------
# Cloud Run container port
# ------------------------------------------------------------
EXPOSE 8080

# ------------------------------------------------------------
# Tini = proper PID 1 / signal handling
# ------------------------------------------------------------
ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/usr/local/bin/entrypoint.sh"]
