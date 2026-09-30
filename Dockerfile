# ============================================================
# VIRGOZKI 4-PROXY + gRPC + XHTTP | CLOUD RUN
# DEBIAN BOOKWORM
# ============================================================

# STAGE 1 — ENVOY
FROM envoyproxy/envoy:v1.39.1 AS envoy

# STAGE 2 — XRAY
FROM ghcr.io/xtls/xray-core:25.12.8 AS xray

# STAGE 3 — FINAL IMAGE
FROM openresty/openresty:1.31.1.1-bookworm-fat AS final

ENV DEBIAN_FRONTEND=noninteractive

# CLOUD RUN DEFAULT ENVIRONMENT
ENV PORT=8080
ENV BIND_ADDR=0.0.0.0

# XRAY ENVIRONMENT
ENV XRAY_LOCATION_ASSET=/usr/local/share/xray
ENV XRAY_LOCATION_CONFIG=/etc/xray

# INTERNAL PORTS
ENV ENVOY_PORT=8080
ENV HAPROXY_PORT=8081
ENV APACHE_PORT=8083
ENV OPENRESTY_PORT=8084
ENV HAPROXY_GRPC_PORT=8086

WORKDIR /opt/virgozki

# INSTALL REQUIRED PACKAGES & CONFIGURE APACHE
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      apache2 \
      apache2-utils \
      haproxy \
      supervisor \
      ca-certificates \
      curl \
      wget \
      unzip \
      tini \
      procps \
      iproute2 \
      net-tools \
      openssl \
      python3 \
      python3-pip \
      netcat-openbsd && \
    a2enmod \
      proxy \
      proxy_http \
      proxy_http2 \
      proxy_wstunnel \
      headers \
      rewrite \
      http2 && \
    a2dissite 000-default && \
    echo "ServerName localhost" >> /etc/apache2/apache2.conf && \
    echo "" > /etc/apache2/ports.conf && \
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
      /usr/share/xray \
      /var/run/apache2 \
      /run/haproxy \
      /var/log/xray \
      /var/log/apache2 && \
    rm -rf /var/lib/apt/lists/*

# COPY BINARIES & ASSETS (FIXED PATHS FOR BUILDX)
COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray

# Kopyahin ang opisyal na Xray assets mula sa source image
COPY --from=xray /usr/local/share/xray/ /usr/local/share/xray/

# Maglagay ng symlink papuntang /usr/share/xray para sa backward compatibility
RUN ln -s /usr/local/share/xray/* /usr/share/xray/ || true

# COPY CONFIGURATION & SCRIPT FILES
COPY supervisord.conf /etc/supervisord.conf
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/openresty/nginx.conf
COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY envoy.yaml /etc/envoy/envoy.yaml
COPY httpd.conf /etc/apache2/conf-available/virgozki.conf
COPY index.html /usr/share/nginx/html/index.html
COPY anti_ddos.py /usr/local/bin/anti_ddos.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# BASIC FILE SETUP & PERMISSIONS
RUN printf 'ok\n' > /usr/share/nginx/html/health && \
    a2enconf virgozki && \
    chmod +x /usr/local/bin/anti_ddos.py /usr/local/bin/entrypoint.sh && \
    chmod 644 /etc/xray/config.json \
              /etc/openresty/nginx.conf \
              /etc/haproxy/haproxy.cfg \
              /etc/envoy/envoy.yaml \
              /etc/apache2/conf-available/virgozki.conf \
              /usr/share/nginx/html/index.html

# BUILD-TIME CONFIGURATION VALIDATION
RUN /usr/local/bin/xray run -test -c /etc/xray/config.json && \
    /usr/local/bin/envoy --mode validate -c /etc/envoy/envoy.yaml && \
    haproxy -c -f /etc/haproxy/haproxy.cfg && \
    apachectl configtest && \
    /usr/local/openresty/bin/openresty -t -c /etc/openresty/nginx.conf

EXPOSE 8080

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisord.conf"]
