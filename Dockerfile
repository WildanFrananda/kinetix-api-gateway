FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8 AS pkl-builder
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates openssl && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ] || [ "$TARGETARCH" = "arm64" ]; then \
      curl -sSL -o /usr/local/bin/pkl https://github.com/apple/pkl/releases/download/0.32.1/pkl-linux-aarch64; \
    else \
      curl -sSL -o /usr/local/bin/pkl https://github.com/apple/pkl/releases/download/0.32.1/pkl-linux-amd64; \
    fi && chmod +x /usr/local/bin/pkl

WORKDIR /app

COPY config/ .

# The config is rendered when the container starts (bin/entrypoint.sh), from the identity public key,
# issuer and browser origins of the environment it starts in, so this image carries none of them and
# the same digest runs everywhere. This step only proves, at build time, that the Pkl evaluates and
# yields a verification key — with a key pair generated here and discarded with this stage.
RUN set -eu; \
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/throwaway.pem 2>/dev/null; \
    openssl pkey -in /tmp/throwaway.pem -pubout -out /tmp/throwaway-public.pem; \
    pkl eval -p identityJwtPublicKey="$(cat /tmp/throwaway-public.pem)" \
             -p jwtIssuer=https://identity.build.invalid \
             -p corsOrigins= \
             -p staffRanges=192.0.2.0/24 \
             -p publicApiHost=api.build.invalid \
             -p backofficeHost=backoffice.build.invalid \
             -p sellerHost=seller.build.invalid \
             -f yaml gateway.pkl -o /tmp/kong.yml; \
    if ! grep -q "rsa_public_key" /tmp/kong.yml; then \
      echo "the rendered config carries no verification key"; exit 1; \
    fi; \
    if ! grep -q "name: ip-restriction" /tmp/kong.yml; then \
      echo "the rendered config carries no staff gate"; exit 1; \
    fi; \
    twins="$(grep -c -- '-internal$' /tmp/kong.yml)"; \
    guards="$(grep -c 'name: pre-function' /tmp/kong.yml)"; \
    if [ "$twins" -eq 0 ] || [ "$twins" != "$guards" ]; then \
      echo "$twins internal twins and $guards plaintext guards"; exit 1; \
    fi; \
    refuses() { \
      if pkl eval -p identityJwtPublicKey="$(cat /tmp/throwaway-public.pem)" \
                  -p jwtIssuer=https://identity.build.invalid \
                  -p corsOrigins= \
                  -p publicApiHost=api.build.invalid \
                  "$@" \
                  -f yaml gateway.pkl -o /tmp/kong-without.yml 2>/dev/null; then \
        echo "the config rendered with only $*"; exit 1; \
      fi; \
    }; \
    refuses -p backofficeHost=backoffice.build.invalid -p sellerHost=seller.build.invalid; \
    refuses -p staffRanges=192.0.2.0/24 -p sellerHost=seller.build.invalid; \
    refuses -p staffRanges=192.0.2.0/24 -p backofficeHost=backoffice.build.invalid; \
    rm -f /tmp/throwaway.pem /tmp/throwaway-public.pem /tmp/kong.yml /tmp/kong-without.yml

# Pin the Kong minor rather than `latest`: the gateway is the platform's only published
# surface, and `latest` means a rebuild can change what terminates every request without a
# single line of this repository changing.
FROM kong:3.9@sha256:aa4a4687b1330e427ad0d3b27a0606b833894297c78abf1a212edc9ba73c8620

# root only long enough to place pkl, the config source and the entrypoint, and to hand the declarative
# directory to Kong's user, which writes kong.yml there at start. The previous `USER root` was never
# reversed, so the gateway ran the whole platform's ingress as uid 0.
USER root
COPY --from=pkl-builder /usr/local/bin/pkl /usr/local/bin/pkl
COPY config/gateway.pkl /usr/local/kong/kinetix/gateway.pkl
COPY config/access_log.conf /usr/local/kong/kinetix/access_log.conf
COPY bin/entrypoint.sh /usr/local/bin/kinetix-entrypoint.sh
RUN mkdir -p /usr/local/kong/declarative \
    && chown kong:kong /usr/local/kong/declarative \
    && chmod 0755 /usr/local/bin/kinetix-entrypoint.sh /usr/local/bin/pkl
USER kong

ENTRYPOINT ["/usr/local/bin/kinetix-entrypoint.sh"]
CMD ["kong", "docker-start"]

ENV KONG_DATABASE=off
ENV KONG_DECLARATIVE_CONFIG=/usr/local/kong/declarative/kong.yml
ENV KONG_NGINX_HTTP_INCLUDE=/usr/local/kong/kinetix/access_log.conf
ENV KONG_PROXY_ACCESS_LOG="logs/access.log kinetix"

# The certificate and key are placed by bin/entrypoint.sh from files or from the environment; they
# are not in this image.
ENV KONG_PROXY_LISTEN="0.0.0.0:8443 ssl, 0.0.0.0:8000"

EXPOSE 8443

# `kong health` checks the local processes, not the listener, so it stays correct now that the
# only listener speaks TLS.
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
    CMD kong health || exit 1
