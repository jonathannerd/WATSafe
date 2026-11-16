# Standalone pure-Dart container for WATSafe HTTPS Relay + Web Push Companion
FROM dart:stable AS build

WORKDIR /app

# Create a pure-Dart pubspec without Flutter SDK requirement for fast cloud builds
RUN printf '%s\n' \
  'name: watsafe' \
  'environment:' \
  '  sdk: ^3.5.0' \
  'dependencies:' \
  '  cryptography: ^2.9.0' \
  '  crypto: ^3.0.8' \
  '  postgres: ^3.6.0' \
  > pubspec.yaml

RUN dart pub get

COPY lib/relay ./lib/relay
COPY backend ./backend

RUN dart compile exe backend/server.dart -o /app/bin/watsafe-relay

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/bin/watsafe-relay /app/bin/watsafe-relay

ENV PORT=8787
ENV WATSAFE_BIND_HOST=0.0.0.0
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/v1/health" || exit 1

ENTRYPOINT ["/app/bin/watsafe-relay"]
