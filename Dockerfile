# ============================================================
# VIRGOZKI 4-PROXY + gRPC | CLOUD RUN
# DEBIAN BOOKWORM
#
# PUBLIC:
#   Cloud Run -> Envoy :8080
#
# INTERNAL:
#   HAProxy   :8081 / :8086
#   Apache    :8083
#   OpenResty :8084
#   Xray      :10000-10015
# ============================================================


# ============================================================
# STAGE 1 — ENVOY
# ============================================================

FROM envoyproxy/envoy:v1.39.1 AS envoy


# ============================================================
# STAGE 2 — XRAY
# ============================================================

FROM ghcr.io/xtls/xray-core:25.12.8 AS xray


# ============================================================
# STAGE 3 — FINAL IMAGE
# ============================================================

FROM openresty/openresty:1.31.1.1-bookworm-fat AS final

ENV DEBIAN_FRONTEND=noninteractive

# ============================================================
# CLOUD RUN
# ============================================================

ENV PORT=8080
ENV BIND_ADDR=0.0.0.0


# ============================================================
# XRAY
# ============================================================

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray
ENV XRAY_LOCATION_CONFIG=/etc/xray


# ============================================================
# INTERNAL PORTS
# ============================================================

ENV ENVOY_PORT=8080
ENV HAPROXY_PORT=8081
ENV APACHE_PORT=8083
ENV OPENRESTY_PORT=8084
ENV HAPROXY_GRPC_PORT=8086


# ============================================================
# WORK DIRECTORY
# ============================================================

WORKDIR /opt/virgozki


# ============================================================
# INSTALL REQUIRED PACKAGES
# ============================================================

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


# ============================================================
# COPY ENVOY
# ============================================================

COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy


# ============================================================
# COPY XRAY
# ============================================================

COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray

COPY --from=xray \
    /usr/local/share/xray/. \
    /usr/local/share/xray/


# ============================================================
# COPY CONFIGURATION FILES
# ============================================================

COPY supervisord.conf /etc/supervisord.conf

COPY config.json /etc/xray/config.json

COPY nginx.conf /etc/openresty/nginx.conf

COPY haproxy.cfg /etc/haproxy/haproxy.cfg

COPY envoy.yaml /etc/envoy/envoy.yaml

COPY httpd.conf /etc/apache2/conf-available/virgozki.conf

COPY index.html /usr/share/nginx/html/index.html

COPY anti_ddos.py /usr/local/bin/anti_ddos.py


# ============================================================
# BASIC FILE SETUP
# ============================================================

RUN printf 'ok\n' > /usr/share/nginx/html/health && \
    a2enconf virgozki && \
    chmod +x /usr/local/bin/anti_ddos.py && \
    chmod 644 /etc/xray/config.json && \
    chmod 644 /etc/openresty/nginx.conf && \
    chmod 644 /etc/haproxy/haproxy.cfg && \
    chmod 644 /etc/envoy/envoy.yaml && \
    chmod 644 /etc/apache2/conf-available/virgozki.conf && \
    chmod 644 /usr/share/nginx/html/index.html


# ============================================================
# CONFIGURATION VALIDATION
# ============================================================

RUN /usr/local/bin/xray run \
        -test \
        -c /etc/xray/config.json && \
    /usr/local/bin/envoy \
        --mode validate \
        -c /etc/envoy/envoy.yaml && \
    haproxy \
        -c \
        -f /etc/haproxy/haproxy.cfg && \
    apachectl \
        -t && \
    /usr/local/openresty/bin/openresty \
        -t \
        -c /etc/openresty/nginx.conf


# ============================================================
# CLOUD RUN PORT
# ============================================================

EXPOSE 8080


# ============================================================
# PROCESS SIGNAL
# ============================================================

STOPSIGNAL SIGTERM


# ============================================================
# INIT
# ============================================================

ENTRYPOINT ["/usr/bin/tini", "--"]


# ============================================================
# SUPERVISOR
# ============================================================

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisord.conf"]
