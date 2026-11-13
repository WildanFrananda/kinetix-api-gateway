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

RUN set -eu; \
    onion=kinetixgatewaybuildabcdefghijklmnopqrstuvwxyz234567abcde.onion; \
    backoffice=backoffice.build.invalid; \
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/throwaway.pem 2>/dev/null; \
    openssl pkey -in /tmp/throwaway.pem -pubout -out /tmp/throwaway-public.pem; \
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
                -subj "/CN=$onion" \
                -addext "subjectAltName=DNS:$onion" \
                -keyout /tmp/onion.key \
                -out /tmp/onion.pem 2>/dev/null; \
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
                -subj "/CN=$backoffice" \
                -addext "subjectAltName=DNS:$backoffice" \
                -keyout /tmp/backoffice.key \
                -out /tmp/backoffice.pem 2>/dev/null; \
    tls="-p backofficeOnionTlsCertFile=/tmp/onion.pem -p backofficeOnionTlsKeyFile=/tmp/onion.key -p backofficeTlsCertFile=/tmp/backoffice.pem -p backofficeTlsKeyFile=/tmp/backoffice.key"; \
    pkl eval -p identityJwtPublicKey="$(cat /tmp/throwaway-public.pem)" \
             -p jwtIssuer=https://identity.build.invalid \
             -p corsOrigins= \
             -p staffRanges=192.0.2.0/24 \
             -p publicApiHost=api.build.invalid \
             -p backofficeHost="$backoffice" \
             -p sellerHost=seller.build.invalid \
             -p backofficeOnionHost="$onion" \
             $tls \
             -f yaml envoy.pkl -o /tmp/envoy.yaml; \
    if ! grep -q "identity_provider" /tmp/envoy.yaml; then \
      echo "the rendered envoy config carries no verification key"; exit 1; \
    fi; \
    if ! grep -q "staff_ranges" /tmp/envoy.yaml; then \
      echo "the rendered envoy config carries no staff gate"; exit 1; \
    fi; \
    refuses() { \
      if pkl eval -p identityJwtPublicKey="$(cat /tmp/throwaway-public.pem)" \
                  -p jwtIssuer=https://identity.build.invalid \
                  -p corsOrigins= \
                  -p publicApiHost=api.build.invalid \
                  "$@" \
                  -f yaml envoy.pkl -o /tmp/envoy-without.yaml 2>/dev/null; then \
        echo "the config rendered with only $*"; exit 1; \
      fi; \
    }; \
    refuses $tls -p backofficeHost="$backoffice" -p sellerHost=seller.build.invalid -p backofficeOnionHost="$onion"; \
    refuses $tls -p staffRanges=192.0.2.0/24 -p sellerHost=seller.build.invalid -p backofficeOnionHost="$onion"; \
    refuses $tls -p staffRanges=192.0.2.0/24 -p backofficeHost="$backoffice" -p backofficeOnionHost="$onion"; \
    refuses $tls -p staffRanges=192.0.2.0/24 -p backofficeHost="$backoffice" -p sellerHost=seller.build.invalid; \
    refuses $tls -p staffRanges=192.0.2.0/24 -p backofficeHost=192.0.2.1 -p sellerHost=seller.build.invalid -p backofficeOnionHost="$onion"; \
    rm -f /tmp/throwaway.pem /tmp/throwaway-public.pem /tmp/onion.pem /tmp/onion.key /tmp/backoffice.pem /tmp/backoffice.key /tmp/envoy.yaml /tmp/envoy-without.yaml

FROM envoyproxy/envoy:v1.31-latest@sha256:caa5b411be1633b90023592a34a7e010c933d6e60206c758f631485e53006865

USER root
COPY --from=pkl-builder /usr/local/bin/pkl /usr/local/bin/pkl
COPY config/envoy.pkl /etc/kinetix/envoy/envoy.pkl
COPY config/envoy/ /etc/kinetix/envoy/envoy/
COPY bin/entrypoint.sh /usr/local/bin/kinetix-entrypoint.sh
RUN groupmod -g 1001 envoy \
    && usermod -u 1001 -g 1001 envoy \
    && mkdir -p /var/lib/envoy \
    && chown -R envoy:envoy /var/lib/envoy /etc/kinetix/envoy /home/envoy \
    && chmod 0700 /var/lib/envoy \
    && chmod 0755 /usr/local/bin/kinetix-entrypoint.sh /usr/local/bin/pkl
USER 1001:1001

ENTRYPOINT ["/usr/local/bin/kinetix-entrypoint.sh"]
CMD ["envoy", "-c", "/var/lib/envoy/envoy.yaml"]

EXPOSE 8443

HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/9901 && printf "GET /ready HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3 && grep -q "LIVE" <&3'
