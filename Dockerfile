# Kinetix API Gateway Dockerfile (Lute Engine Runtime)
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        LUTE_ARCH="x86_64"; \
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        LUTE_ARCH="aarch64"; \
    else \
        LUTE_ARCH="x86_64"; \
    fi && \
    curl -sSL "https://github.com/luau-lang/lute/releases/download/v1.0.0/lute-linux-${LUTE_ARCH}.zip" -o /tmp/lute.zip && \
    unzip /tmp/lute.zip -d /usr/local/bin/ && \
    chmod +x /usr/local/bin/lute || true

FROM debian:bookworm-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/lute /usr/local/bin/lute

COPY . .

EXPOSE 8080

ENV PORT=8080
ENV IDENTITY_SERVICE_URL=http://kinetix-identity-service:5000
ENV CATALOG_SERVICE_URL=http://kinetix-catalog-service:8000
ENV WAREHOUSE_SERVICE_URL=http://kinetix-warehouse-service:3000
ENV MATCHING_SERVICE_URL=http://kinetix-matching-service:4000

CMD ["lute", "run", "src/main.luau"]
