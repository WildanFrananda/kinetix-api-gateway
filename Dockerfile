FROM debian:bookworm-slim AS pkl-builder
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ] || [ "$TARGETARCH" = "arm64" ]; then \
      curl -sSL -o /usr/local/bin/pkl https://github.com/apple/pkl/releases/download/0.32.1/pkl-linux-aarch64; \
    else \
      curl -sSL -o /usr/local/bin/pkl https://github.com/apple/pkl/releases/download/0.32.1/pkl-linux-amd64; \
    fi && chmod +x /usr/local/bin/pkl

WORKDIR /app

COPY config/ .

RUN mkdir -p /build && pkl eval -f yaml gateway.pkl -o /build/kong.yml

# Pin the Kong minor rather than `latest`: the gateway is the platform's only published
# surface, and `latest` means a rebuild can change what terminates every request without a
# single line of this repository changing.
FROM kong:3.9

# root only long enough to place the generated config, then drop back to the image's own
# unprivileged user. The previous `USER root` was never reversed, so the gateway ran the
# whole platform's ingress as uid 0.
USER root
COPY --from=pkl-builder /build/kong.yml /usr/local/kong/declarative/kong.yml
RUN chown kong:kong /usr/local/kong/declarative/kong.yml
USER kong

ENV KONG_DATABASE=off
ENV KONG_DECLARATIVE_CONFIG=/usr/local/kong/declarative/kong.yml
# HTTP only for now. The 8443 listener was declared with no certificate configured, so it
# served Kong's throwaway self-signed default — TLS that no client could verify. Real TLS
# termination, and the removal of the plaintext listener, land with the trust boundary.
ENV KONG_PROXY_LISTEN="0.0.0.0:8080"

EXPOSE 8080
