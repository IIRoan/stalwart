FROM stalwartlabs/stalwart:v0.16

ARG FRPC_VERSION=0.69.1
ARG STALWART_CLI_VERSION=1.0.8
ARG BUILD_TIMESTAMP=2026-06-12-6

USER root

RUN apt-get update \
    && apt-get install -yq --no-install-recommends curl iproute2 xz-utils \
    && curl -fsSL "https://github.com/fatedier/frp/releases/download/v${FRPC_VERSION}/frp_${FRPC_VERSION}_linux_amd64.tar.gz" \
        | tar xz -C /tmp \
    && mv "/tmp/frp_${FRPC_VERSION}_linux_amd64/frpc" /usr/local/bin/frpc \
    && chmod 755 /usr/local/bin/frpc \
    && rm -rf /tmp/frp_* \
    && curl -fsSL "https://github.com/stalwartlabs/cli/releases/download/v${STALWART_CLI_VERSION}/stalwart-cli-x86_64-unknown-linux-gnu.tar.xz" \
        | tar xJ -C /tmp \
    && mv /tmp/stalwart-cli-x86_64-unknown-linux-gnu/stalwart-cli /usr/local/bin/stalwart-cli \
    && rm -rf /tmp/stalwart-cli-x86_64-unknown-linux-gnu \
    && chmod 755 /usr/local/bin/stalwart-cli \
    && rm -rf /var/lib/apt/lists/* \
    && chmod 666 /etc/hosts

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod 755 /usr/local/bin/railway-entrypoint.sh \
    && chown stalwart:stalwart /usr/local/bin/railway-entrypoint.sh

USER stalwart

EXPOSE 25 465 587 993 443 8080

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
