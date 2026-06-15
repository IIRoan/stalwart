FROM twinproduction/gatus:stable AS upstream

FROM alpine:3.20

RUN apk add --no-cache ca-certificates apache2-utils tzdata wget \
    && mkdir -p /etc/gatus /data \
    && rm -rf /var/cache/apk/*

COPY --from=upstream /gatus /usr/local/bin/gatus
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config.default.yaml /etc/gatus/config.default.yaml

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/gatus

ENV GATUS_CONFIG_PATH=/data/config.yaml
ENV PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD wget -q -O - "http://127.0.0.1:${PORT}/health" > /dev/null || exit 1

CMD ["/usr/local/bin/entrypoint.sh"]
