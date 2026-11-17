# Standalone pure-Dart container for WATSafe HTTPS Relay + Web Push Companion
# Aligned with Flutter 3.47.9 / Dart 3.13.7 used in CI and local development.
FROM dart:3.13.7-sdk AS build

WORKDIR /app

# Pure-Dart pubspec aligned with root pubspec.yaml backend dependencies
RUN printf '%s\n' \
  'name: watsafe' \
  'environment:' \
  '  sdk: ^3.13.0' \
  'dependencies:' \
  '  cryptography: ^2.9.0' \
  '  crypto: ^3.0.8' \
  '  postgres: ^3.6.0' \
  > pubspec.yaml

RUN dart pub get

COPY lib/relay ./lib/relay
COPY backend ./backend

RUN mkdir -p /app/bin && dart compile exe backend/server.dart -o /app/bin/watsafe-relay

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/bin/watsafe-relay /app/bin/watsafe-relay
RUN mkdir -p /tmp/watsafe-ephemeral && chmod 700 /tmp/watsafe-ephemeral

ENV PORT=8787
ENV WATSAFE_BIND_HOST=0.0.0.0
# Container filesystems are ephemeral across redeploys/spin-downs unless an external
# database is configured. Set AIVEN_DATABASE_URL as an environment secret in cloud
# deployments so pairings, push subscriptions, events, and VAPID keys persist durably.
ENV WATSAFE_DATA_DIR=/tmp/watsafe-ephemeral
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/v1/health" || exit 1

ENTRYPOINT ["/app/bin/watsafe-relay"]
