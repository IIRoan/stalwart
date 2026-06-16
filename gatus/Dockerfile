# Build Gatus with 90-day period uptime support (upstream PR #1651; CarmJos fork).
FROM golang:1.24-alpine AS gatus-builder

RUN apk add --no-cache ca-certificates git
WORKDIR /src
RUN git clone --depth 1 https://github.com/CarmJos/gatus.git .
COPY assets/solace-logo.png web/static/solace-logo.png
COPY assets/favicon.ico web/static/favicon.ico
COPY assets/favicon-16x16.png web/static/favicon-16x16.png
COPY assets/favicon-32x32.png web/static/favicon-32x32.png
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /gatus .

FROM alpine:3.20

RUN apk add --no-cache ca-certificates apache2-utils tzdata wget \
    && mkdir -p /etc/gatus /data \
    && rm -rf /var/cache/apk/*

COPY --from=gatus-builder /gatus /usr/local/bin/gatus
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config.default.yaml /etc/gatus/config.default.yaml

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/gatus

ENV GATUS_CONFIG_PATH=/data/config.yaml
ENV PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD wget -q -O - "http://127.0.0.1:${PORT}/health" > /dev/null || exit 1

CMD ["/usr/local/bin/entrypoint.sh"]
