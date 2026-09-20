FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV XRAY_LOCATION_ASSET=/usr/local/share/xray/
ENV PORT=8080

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget unzip gnupg tini python3 \
    apache2 haproxy \
    && rm -rf /var/lib/apt/lists/*

RUN a2dismod mpm_prefork >/dev/null 2>&1 || true; \
    a2enmod mpm_event proxy proxy_http proxy_http2 proxy_wstunnel http2 reqtimeout headers >/dev/null

# OpenResty official repository
RUN mkdir -p /etc/apt/keyrings && \
    wget -qO- https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /etc/apt/keyrings/openresty.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/openresty.gpg] https://openresty.org/package/debian bookworm openresty" > /etc/apt/sources.list.d/openresty.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends openresty && \
    rm -rf /var/lib/apt/lists/*

# Envoy official repository
RUN mkdir -p /etc/apt/keyrings && \
    wget -qO- https://apt.envoyproxy.io/signing.key | gpg --dearmor -o /etc/apt/keyrings/envoy-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/envoy-keyring.gpg] https://apt.envoyproxy.io bookworm main" > /etc/apt/sources.list.d/envoy.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends envoy && \
    rm -rf /var/lib/apt/lists/*

# Xray Core (amd64 / x86_64)
RUN set -eux; \
    mkdir -p /tmp/xray /usr/local/share/xray; \
    wget --timeout=120 --tries=3 --retry-connrefused -qO /tmp/xray.zip \
      https://github.com/XTLS/Xray-core/releases/download/v24.10.31/Xray-linux-64.zip; \
    test -s /tmp/xray.zip; \
    echo "Xray zip downloaded successfully"; \
    unzip -q /tmp/xray.zip -d /tmp/xray; \
    test -x /tmp/xray/xray; \
    install -m 0755 /tmp/xray/xray /usr/local/bin/xray; \
    install -m 0644 /tmp/xray/geoip.dat /usr/local/share/xray/geoip.dat; \
    install -m 0644 /tmp/xray/geosite.dat /usr/local/share/xray/geosite.dat; \
    /usr/local/bin/xray version; \
    rm -rf /tmp/xray /tmp/xray.zip

COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY index.html /usr/local/openresty/nginx/html/index.html
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    mkdir -p /run/apache2 /var/log/apache2 /var/lock/apache2

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
