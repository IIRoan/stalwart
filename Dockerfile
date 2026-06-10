FROM stalwartlabs/stalwart:v0.16

USER root

COPY railway-entrypoint.sh /railway-entrypoint.sh
RUN chmod +x /railway-entrypoint.sh

USER stalwart

ENTRYPOINT ["/railway-entrypoint.sh"]