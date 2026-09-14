FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS pkl-builder
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
             -f yaml gateway.pkl -o /tmp/kong.yml; \
    if ! grep -q "rsa_public_key" /tmp/kong.yml; then \
      echo "the rendered config carries no verification key"; exit 1; \
    fi; \
    rm -f /tmp/throwaway.pem /tmp/throwaway-public.pem /tmp/kong.yml

# Pin the Kong minor rather than `latest`: the gateway is the platform's only published
# surface, and `latest` means a rebuild can change what terminates every request without a
# single line of this repository changing.
FROM kong:3.9@sha256:2a8cf3b110cdaba1cb00adc665b8635ed1fc75c907f7a4298613c68e4976de0a

# root only long enough to place pkl, the config source and the entrypoint, and to hand the declarative
# directory to Kong's user, which writes kong.yml there at start. The previous `USER root` was never
# reversed, so the gateway ran the whole platform's ingress as uid 0.
USER root
COPY --from=pkl-builder /usr/local/bin/pkl /usr/local/bin/pkl
COPY config/gateway.pkl /usr/local/kong/kinetix/gateway.pkl
COPY bin/entrypoint.sh /usr/local/bin/kinetix-entrypoint.sh
RUN mkdir -p /usr/local/kong/declarative \
    && chown kong:kong /usr/local/kong/declarative \
    && chmod 0755 /usr/local/bin/kinetix-entrypoint.sh /usr/local/bin/pkl
USER kong

ENTRYPOINT ["/usr/local/bin/kinetix-entrypoint.sh"]
CMD ["kong", "docker-start"]

ENV KONG_DATABASE=off
ENV KONG_DECLARATIVE_CONFIG=/usr/local/kong/declarative/kong.yml

# TLS only. There is deliberately no plaintext listener beside it: an 8080 that still answers is
# an 8080 that clients keep using, and every token this gateway now verifies would travel in
# clear text on the way to being verified. The previous 8443 listener was declared with no
# certificate and served Kong's throwaway self-signed default, which no client could verify —
# that is not the same as having TLS.
#
# The certificate and key are placed by bin/entrypoint.sh from files or from the environment; they
# are not in this image.
ENV KONG_PROXY_LISTEN="0.0.0.0:8443 ssl"

EXPOSE 8443

# `kong health` checks the local processes, not the listener, so it stays correct now that the
# only listener speaks TLS.
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
    CMD kong health || exit 1
