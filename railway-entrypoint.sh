#!/bin/bash
# Railway entrypoint for the Typebot Builder.
#
# What this adds over the stock image:
#   1. A built-in mailbox (mailpit) bound to loopback, so Typebot's only
#      first-party sign-in method — the emailed login code — works without the
#      deployer having to supply a third-party SMTP account. The mailbox is
#      published at /inbox behind HTTP basic auth, because it holds login codes.
#   2. An nginx gateway on Railway's injected port, with the Next.js server
#      pinned to an internal port. Railway injects PORT into every service and
#      that injection overrides the image's own ENV PORT, so the app and the
#      gateway cannot both read it.
#   3. The object-storage bucket Typebot uploads into, created at boot instead
#      of by a separate one-shot service.
set -euo pipefail

log() { echo "[railway-entrypoint] $*"; }

GATEWAY_PORT="${PORT:-8080}"
APP_PORT="${APP_PORT:-3000}"
MAILPIT_HTTP_PORT="${MAILPIT_HTTP_PORT:-8025}"
MAILPIT_SMTP_PORT="${SMTP_PORT:-1025}"

if [ -z "${INBOX_PASSWORD:-}" ]; then
    log "FATAL: INBOX_PASSWORD is empty. The built-in mailbox holds Typebot login"
    log "       codes, so it is never served without a password. Refusing to boot."
    exit 1
fi
INBOX_USER="${INBOX_USER:-admin}"

if [ -z "${ADMIN_EMAIL:-}" ]; then
    log "FATAL: ADMIN_EMAIL is empty. With DISABLE_SIGNUP=true and no admin address"
    log "       nobody could ever create an account. Refusing to boot."
    exit 1
fi

# Typebot registers its email provider only when NEXT_PUBLIC_SMTP_FROM is set
# AND SMTP_AUTH_DISABLED is false (packages/auth/src/lib/providers.ts). Leaving
# SMTP_USERNAME/SMTP_PASSWORD unset makes nodemailer connect with no auth, which
# is what the loopback mailbox expects.
export SMTP_HOST="${SMTP_HOST:-127.0.0.1}"
export SMTP_PORT="${MAILPIT_SMTP_PORT}"
export SMTP_SECURE="${SMTP_SECURE:-false}"
export SMTP_AUTH_DISABLED="${SMTP_AUTH_DISABLED:-false}"
export NEXT_PUBLIC_SMTP_FROM="${NEXT_PUBLIC_SMTP_FROM:-Typebot <${ADMIN_EMAIL}>}"
unset SMTP_USERNAME SMTP_PASSWORD || true

# --- mailbox ---------------------------------------------------------------
log "starting mailbox on 127.0.0.1:${MAILPIT_SMTP_PORT} (ui 127.0.0.1:${MAILPIT_HTTP_PORT}/inbox)"
MP_MAX_MESSAGES=200 \
mailpit \
    --listen "127.0.0.1:${MAILPIT_HTTP_PORT}" \
    --smtp "127.0.0.1:${MAILPIT_SMTP_PORT}" \
    --webroot inbox \
    --database /var/lib/mailpit/mailpit.db \
    --quiet &

# --- gateway ---------------------------------------------------------------
htpasswd -bBc /etc/nginx/inbox.htpasswd "$INBOX_USER" "$INBOX_PASSWORD" >/dev/null 2>&1
sed -e "s/__GATEWAY_PORT__/${GATEWAY_PORT}/g" \
    -e "s/__APP_PORT__/${APP_PORT}/g" \
    -e "s/__MAILPIT_HTTP_PORT__/${MAILPIT_HTTP_PORT}/g" \
    /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
nginx -t
log "starting gateway on :${GATEWAY_PORT} (app :${APP_PORT}, /inbox -> mailbox)"
nginx

# --- object storage --------------------------------------------------------
# Typebot writes uploads through presigned URLs, so the bucket has to exist and
# has to be publicly readable for a bot to send an uploaded file back to a
# visitor. Upstream's Railway templates do this with a one-shot `minio/mc`
# service that the deployer is told to delete afterwards.
if [ -n "${S3_ENDPOINT:-}" ] && [ -n "${S3_ACCESS_KEY:-}" ] && [ -n "${S3_SECRET_KEY:-}" ]; then
    S3_SCHEME=https
    [ "${S3_SSL:-true}" = "true" ] || S3_SCHEME=http
    S3_URL="${S3_SCHEME}://${S3_ENDPOINT}:${S3_PORT:-443}"
    for attempt in 1 2 3 4 5 6; do
        if mc alias set typebot-s3 "$S3_URL" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null 2>&1; then
            mc mb --ignore-existing "typebot-s3/${S3_BUCKET:-typebot}" >/dev/null 2>&1 || true
            mc anonymous set download "typebot-s3/${S3_BUCKET:-typebot}" >/dev/null 2>&1 || true
            log "bucket ${S3_BUCKET:-typebot} ready on ${S3_URL}"
            break
        fi
        log "object storage not reachable yet (attempt ${attempt}) — retrying"
        sleep 5
    done
else
    log "no S3 credentials in the environment — skipping bucket setup"
fi

# --- app -------------------------------------------------------------------
export PORT="$APP_PORT"
export HOSTNAME="${HOSTNAME:-0.0.0.0}"

cd /app/apps/builder
node -e "const { configureRuntimeEnv } = require('next-runtime-env/build/configure'); configureRuntimeEnv();"
cd /app

./node_modules/.bin/prisma migrate deploy \
    --schema=packages/prisma/postgresql/schema.prisma \
    --config=packages/prisma/prisma.config.ts

log "starting builder on :${APP_PORT}"
exec setpriv --reuid=1000 --regid=1000 --init-groups \
    env NODE_OPTIONS=--no-node-snapshot HOSTNAME="$HOSTNAME" PORT="$APP_PORT" \
    node apps/builder/server.js
