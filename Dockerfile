FROM stalwartlabs/stalwart:v0.16

USER root

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod 755 /usr/local/bin/railway-entrypoint.sh \
    && chown stalwart:stalwart /usr/local/bin/railway-entrypoint.sh

USER stalwart

EXPOSE 25 465 587 993 443 8080

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
