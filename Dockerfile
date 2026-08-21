# Kinetix API Gateway Dockerfile (Luau / Lute Runtime)
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    ca-certificates \
    build-essential \
    cmake \
    git \
    && rm -rf /var/lib/apt/lists/*

# Download or build Lute runtime CLI binary
RUN curl -sSL https://github.com/luau-lang/luau/releases/download/0.655/luau-ubuntu.zip -o /tmp/luau.zip \
    && unzip /tmp/luau.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/luau* || true

FROM debian:bookworm-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin /usr/local/bin

COPY . .

EXPOSE 8080

ENV PORT=8080
ENV CATALOG_SERVICE_URL=http://kinetix-catalog-service:8000
ENV WAREHOUSE_SERVICE_URL=http://kinetix-warehouse-service:3000
ENV MATCHING_SERVICE_URL=http://kinetix-matching-service:4000

CMD ["luau", "src/main.luau"]
