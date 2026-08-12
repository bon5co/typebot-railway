FROM baptistearno/typebot-builder:3.17.2

USER root

ARG MAILPIT_VERSION=1.30.7

RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx apache2-utils ca-certificates curl util-linux \
 && curl -fsSL "https://github.com/axllent/mailpit/releases/download/v${MAILPIT_VERSION}/mailpit-linux-amd64.tar.gz" \
      | tar -xz -C /usr/local/bin mailpit \
 && chmod +x /usr/local/bin/mailpit \
 && curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/mc" -o /usr/local/bin/mc \
 && chmod +x /usr/local/bin/mc \
 && apt-get purge -y curl \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/lib/mailpit /var/lib/nginx /var/log/nginx \
 && chown -R node:node /var/lib/mailpit

# The upstream image bakes PORT=3000. Railway injects its own PORT into every
# service and that injection wins, so the Next.js server is pinned to an
# internal port by the entrypoint and nginx takes the injected one.
ENV APP_PORT=3000 \
    MAILPIT_HTTP_PORT=8025 \
    SMTP_HOST=127.0.0.1 \
    SMTP_PORT=1025 \
    SMTP_SECURE=false \
    SMTP_AUTH_DISABLED=false \
    SCOPE=builder \
    HOSTNAME=0.0.0.0 \
    DISABLE_SIGNUP=true \
    NEXT_PUBLIC_BOT_FILE_UPLOAD_MAX_SIZE=10 \
    S3_PORT=443 \
    S3_SSL=true

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY nginx.conf.template /etc/nginx/nginx.conf.template
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
