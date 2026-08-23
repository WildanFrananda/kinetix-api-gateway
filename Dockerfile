FROM openresty/openresty:alpine

# Install ca-certificates for HTTPS outbound requests
RUN apk add --no-cache ca-certificates

# Copy NGINX configuration & Lua scripts
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY lua/ /usr/local/openresty/nginx/lua/

EXPOSE 8080

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
