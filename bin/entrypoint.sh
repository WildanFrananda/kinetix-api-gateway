#!/usr/bin/env sh
# Renders Kong's declarative config and places its TLS material, then hands over to the image's own
# entrypoint.
#
# Both happen here, at container start, so that one image serves every environment and the digest CI
# scanned is the digest that runs. Nothing environment-specific is in the image: identity's public key,
# the trusted issuer and the browser origins arrive as environment variables, and the certificate
# arrives either as files or as base64 variables.
#
# The certificate and key are never build arguments: a build argument is recorded in the image and
# `docker history` prints it, and the private key of the platform's only public surface must not be
# baked into a distributable layer.
set -eu

# ── declarative config ───────────────────────────────────────────────────────────────────────────

if [ -z "${KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64:-}" ]; then
  echo "KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64 is required: the gateway cannot verify tokens without identity's public key." >&2
  exit 1
fi
if [ -z "${KINETIX_JWT_ISSUER:-}" ]; then
  echo "KINETIX_JWT_ISSUER is required: it is the one issuer this gateway trusts." >&2
  exit 1
fi
# Must be set, and may be empty. Empty means no browser origin may read a response, and the cors plugin
# is left out; an unset variable is a forgotten one, and is refused rather than read as either answer.
if [ -z "${KINETIX_GATEWAY_CORS_ORIGINS+set}" ]; then
  echo "KINETIX_GATEWAY_CORS_ORIGINS must be set. Empty is allowed, and means no browser origin is trusted." >&2
  exit 1
fi

CONFIG="${KONG_DECLARATIVE_CONFIG:-/usr/local/kong/declarative/kong.yml}"
umask 077

public_key="$(mktemp)"
printf '%s' "$KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64" | base64 -d > "$public_key"
if ! grep -q "BEGIN PUBLIC KEY" "$public_key"; then
  echo "KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64 did not decode to a PEM public key" >&2
  exit 1
fi

pkl eval \
  -p identityJwtPublicKey="$(cat "$public_key")" \
  -p jwtIssuer="$KINETIX_JWT_ISSUER" \
  -p corsOrigins="$KINETIX_GATEWAY_CORS_ORIGINS" \
  -f yaml /usr/local/kong/kinetix/gateway.pkl -o "$CONFIG"
rm -f "$public_key"

# Assert the result, not pkl's exit status alone: a gateway that starts without a verification key
# routes everything and authenticates nothing.
if ! grep -q "rsa_public_key" "$CONFIG"; then
  echo "the rendered config carries no verification key" >&2
  exit 1
fi
export KONG_DECLARATIVE_CONFIG="$CONFIG"

# ── TLS ──────────────────────────────────────────────────────────────────────────────────────────
#
# Two sources, and exactly one of them:
#
#   files   KINETIX_GATEWAY_TLS_CERT_FILE / _KEY_FILE — production. The certificate is renewed on disk
#           every sixty days, and a renewal is a file swap and a restart, not a re-encryption of the
#           secret store.
#   inline  KINETIX_GATEWAY_TLS_CERT_B64 / _KEY_B64 — the lab, whose certificate lives in the store.
#
# Both at once is refused: two sources for one certificate is a question of which one is live, and the
# answer should not depend on the order of the checks below.

files="${KINETIX_GATEWAY_TLS_CERT_FILE:-}${KINETIX_GATEWAY_TLS_KEY_FILE:-}"
inline="${KINETIX_GATEWAY_TLS_CERT_B64:-}${KINETIX_GATEWAY_TLS_KEY_B64:-}"

if [ -n "$files" ] && [ -n "$inline" ]; then
  echo "TLS is configured twice: set either the _FILE pair or the _B64 pair, not both." >&2
  exit 1
fi

if [ -n "$files" ]; then
  if [ -z "${KINETIX_GATEWAY_TLS_CERT_FILE:-}" ] || [ -z "${KINETIX_GATEWAY_TLS_KEY_FILE:-}" ]; then
    echo "KINETIX_GATEWAY_TLS_CERT_FILE and KINETIX_GATEWAY_TLS_KEY_FILE must be set together." >&2
    exit 1
  fi
  # grep reads the files as this user, so an unreadable key fails here, by name, rather than inside Kong.
  grep -q "BEGIN CERTIFICATE" "$KINETIX_GATEWAY_TLS_CERT_FILE" 2>/dev/null || {
    echo "$KINETIX_GATEWAY_TLS_CERT_FILE is not readable by $(id -un) or is not a PEM certificate" >&2
    exit 1
  }
  grep -q "PRIVATE KEY" "$KINETIX_GATEWAY_TLS_KEY_FILE" 2>/dev/null || {
    echo "$KINETIX_GATEWAY_TLS_KEY_FILE is not readable by $(id -un) or is not a PEM private key" >&2
    exit 1
  }
  export KONG_SSL_CERT="$KINETIX_GATEWAY_TLS_CERT_FILE"
  export KONG_SSL_CERT_KEY="$KINETIX_GATEWAY_TLS_KEY_FILE"
elif [ -n "${KINETIX_GATEWAY_TLS_CERT_B64:-}" ] && [ -n "${KINETIX_GATEWAY_TLS_KEY_B64:-}" ]; then
  TLS_DIR="${KONG_TLS_DIR:-/tmp/kong-tls}"
  mkdir -p "$TLS_DIR"
  chmod 700 "$TLS_DIR"

  printf '%s' "$KINETIX_GATEWAY_TLS_CERT_B64" | base64 -d > "$TLS_DIR/server.pem"
  printf '%s' "$KINETIX_GATEWAY_TLS_KEY_B64"  | base64 -d > "$TLS_DIR/server.key"

  # Assert the decoded material, not the exit status of base64. A truncated variable decodes
  # without complaint and Kong then fails to start with an error about the file, not the value.
  grep -q "BEGIN CERTIFICATE" "$TLS_DIR/server.pem" || {
    echo "KINETIX_GATEWAY_TLS_CERT_B64 did not decode to a PEM certificate" >&2
    exit 1
  }
  grep -q "PRIVATE KEY" "$TLS_DIR/server.key" || {
    echo "KINETIX_GATEWAY_TLS_KEY_B64 did not decode to a PEM private key" >&2
    exit 1
  }
  export KONG_SSL_CERT="$TLS_DIR/server.pem"
  export KONG_SSL_CERT_KEY="$TLS_DIR/server.key"
else
  echo "TLS is required: set KINETIX_GATEWAY_TLS_CERT_FILE and _KEY_FILE, or KINETIX_GATEWAY_TLS_CERT_B64 and _KEY_B64." >&2
  echo "The gateway serves TLS only; there is no plaintext listener to fall back to." >&2
  exit 1
fi

exec /docker-entrypoint.sh "$@"
