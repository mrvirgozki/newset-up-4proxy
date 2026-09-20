# ============================================================
# VIRGOZKI 4-PROXY + gRPC | CLOUD RUN | DEBIAN BOOKWORM
# ✅ FIXED: Paths, Permissions, Cloud Run Compliance, Panel Serving
# ============================================================

# --- Dependency Stages ---
FROM envoyproxy/envoy:v1.39.1 AS envoy
FROM ghcr.io/xtls/xray-core:25.12.8 AS xray

# --- Base Image ---
FROM openresty/openresty:1.31.1.1-bookworm-fat

ENV DEBIAN_FRONTEND=noninteractive
ENV XRAY_LOCATION_ASSET=/usr/local/share/xray
ENV XRAY_LOCATION_CONFIG=/etc/xray
# ✅ Cloud Run requires app to bind to ALL interfaces
ENV BIND_ADDR=0.0.0.0
ENV PORT=8080

WORKDIR /opt/virgozki

# --- Install Dependencies ---
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
    && a2enmod proxy proxy_http proxy_http2 proxy_wstunnel headers rewrite http2 \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- Copy Binaries ---
COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=xray /usr/local/share/xray /usr/local/share/xray

# --- Create Directories ---
RUN mkdir -p \
        /etc/xray \
        /var/log/xray \
        /tmp/virgozki-logs \
        /tmp/virgozki \
        /run/apache2 \
        /var/run/apache2 \
        /var/run/haproxy \
    && chmod -R 777 /tmp /run /var/run

# ✅ FIXED: Copy files to MATCH NGINX CONFIG PATHS
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/openresty/nginx.conf
# ✅ Matches root path in nginx.conf
COPY index.html /usr/share/nginx/html/index.html
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# --- Permissions ---
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && chmod 644 /etc/xray/config.json \
    && chmod 644 /etc/openresty/nginx.conf \
    && chmod -R 755 /usr/share/nginx/html

# ✅ Cloud Run Default Port
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]

