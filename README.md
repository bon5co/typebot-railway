# typebot-railway

Wrapper image for deploying [Typebot](https://github.com/baptisteArno/typebot.io) on
Railway, used by the `Typebot` marketplace template.

Upstream image: `baptistearno/typebot-builder:3.17.2`.
Published image: `ghcr.io/bon5co/typebot-railway-builder`.

## What the wrapper adds

1. **A built-in mailbox, so sign-in works with no third-party SMTP account.**
   Typebot's only first-party sign-in method is an emailed login code
   (`packages/auth/src/lib/providers.ts` registers the Nodemailer provider only when
   `NEXT_PUBLIC_SMTP_FROM` is set and `SMTP_AUTH_DISABLED` is false; everything else is
   OAuth). The image runs [mailpit](https://github.com/axllent/mailpit) on loopback and
   points Typebot's SMTP at it, so the login code is delivered inside the container and
   read at `/inbox` — behind HTTP basic auth, because that mailbox is the credential
   surface of the whole deployment.

2. **An nginx gateway on Railway's injected port.** Railway injects `PORT` into every
   service and that injection overrides the image's own `ENV PORT`, so the Next.js server
   and the gateway cannot both read it. The entrypoint pins the app to `APP_PORT` (3000)
   and gives nginx the injected port, which is also the port Railway's healthcheck dials.

3. **Registration closed by default.** `DISABLE_SIGNUP=true` is baked in, so only the
   address in `ADMIN_EMAIL` can create an account
   (`packages/auth/src/helpers/createAuthPrismaAdapter.ts`). Without it, anybody who
   reaches the builder URL can register on the deployer's instance.

4. **The upload bucket created at boot** instead of by a separate one-shot `minio/mc`
   service that the deployer is then told to delete.

5. **The app runs as uid 1000**, not root: nginx and mailpit start as root, then the
   Next.js server is dropped with `setpriv`.

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `ADMIN_EMAIL` | yes | The one address allowed to create an account. Boot fails if empty. |
| `INBOX_PASSWORD` | yes | Basic-auth password for `/inbox`. Boot fails if empty. |
| `INBOX_USER` | no | Basic-auth user for `/inbox`, default `admin`. |
| `DATABASE_URL` | yes | PostgreSQL connection string. |
| `ENCRYPTION_SECRET` | yes | 32 chars. Also next-auth's signing secret (`nextAuth.ts` passes it as `secret`). |
| `REDIS_URL` | no | Enables Typebot's sign-in rate limiters; without it they are disabled. |
| `S3_ENDPOINT` / `S3_ACCESS_KEY` / `S3_SECRET_KEY` / `S3_BUCKET` | no | Object storage for uploads. The bucket is created and made publicly readable at boot. |
| `PORT` | injected | Gateway port. The app itself is pinned to `APP_PORT`. |
