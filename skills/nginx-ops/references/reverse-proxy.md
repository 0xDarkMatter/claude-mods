# Reverse Proxy Reference

Comprehensive guide to Nginx reverse proxy configuration: upstream blocks, load balancing algorithms, proxy headers, WebSocket and gRPC proxying, caching, and production-ready configurations.

---

## Table of Contents

1. [Upstream Blocks](#upstream-blocks)
2. [Load Balancing Algorithms](#load-balancing-algorithms)
3. [Health Checks](#health-checks)
4. [Proxy Headers](#proxy-headers)
5. [WebSocket Proxy](#websocket-proxy)
6. [gRPC Proxy](#grpc-proxy)
7. [Proxy Caching](#proxy-caching)
8. [Proxy Buffering](#proxy-buffering)
9. [Keepalive Connections](#keepalive-connections)
10. [Timeout Configuration](#timeout-configuration)
11. [Real-World Configurations](#real-world-configurations)

---

## Upstream Blocks

An `upstream` block defines a group of backend servers that Nginx can proxy requests to.

### Basic Upstream

```nginx
upstream backend {
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
}

server {
    listen 80;
    location / {
        proxy_pass http://backend;
    }
}
```

### Server Directive Parameters

```nginx
upstream backend {
    # Basic server
    server 127.0.0.1:3000;

    # Weighted server - receives 3x traffic
    server 127.0.0.1:3001 weight=3;

    # Backup server - only used when all primary servers are down
    server 127.0.0.1:3002 backup;

    # Mark server as permanently unavailable
    server 127.0.0.1:3003 down;

    # Failure detection: after 3 fails within 30s, mark unavailable for 30s
    server 127.0.0.1:3004 max_fails=3 fail_timeout=30s;

    # Limit concurrent connections to this server
    server 127.0.0.1:3005 max_conns=100;

    # Unix socket backend
    server unix:/var/run/app.sock;

    # Resolve hostname (requires resolver directive)
    server backend.service.consul resolve;
}
```

### Parameter Reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| `weight=N` | 1 | Relative weight for weighted load balancing |
| `max_fails=N` | 1 | Number of failed attempts before marking unavailable |
| `fail_timeout=T` | 10s | Time to consider fails AND duration to mark unavailable |
| `backup` | - | Only used when all non-backup servers are unavailable |
| `down` | - | Permanently marks server as unavailable |
| `max_conns=N` | 0 (unlimited) | Maximum concurrent connections to this server |
| `resolve` | - | Monitor DNS changes and update upstream automatically |
| `slow_start=T` | 0 | Gradually increase traffic to recovered server (Nginx Plus) |

---

## Load Balancing Algorithms

### Round-Robin (Default)

Distributes requests sequentially across servers. No directive needed.

```nginx
upstream backend {
    # Round-robin is the default - no directive needed
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
}
```

**Use when:** Backends are homogeneous and requests have similar processing time.

### Weighted Round-Robin

```nginx
upstream backend {
    server 127.0.0.1:3000 weight=5;   # Gets 5/8 of requests
    server 127.0.0.1:3001 weight=2;   # Gets 2/8 of requests
    server 127.0.0.1:3002 weight=1;   # Gets 1/8 of requests
}
```

**Use when:** Backends have different capacity (CPU, memory).

### Least Connections

Routes to the server with the fewest active connections.

```nginx
upstream backend {
    least_conn;
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
}
```

**Use when:** Requests have variable processing time. Prevents slow requests from piling up on one server.

### IP Hash

Routes requests from the same client IP to the same backend server (session persistence).

```nginx
upstream backend {
    ip_hash;
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
}
```

**Use when:** Application requires sticky sessions and you can't use external session storage.

**Caveat:** If clients are behind a NAT/proxy, many IPs map to one, causing uneven distribution.

### Random

Randomly selects a server for each request.

```nginx
upstream backend {
    random;
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
}
```

### Random with Two Choices

Picks two servers at random, then selects the one with fewer connections (power of two choices).

```nginx
upstream backend {
    random two least_conn;
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
}
```

**Use when:** Large number of backends where least_conn coordination overhead is high.

### Hash (Consistent Hashing)

Map requests to servers based on a configurable key.

```nginx
upstream backend {
    hash $request_uri consistent;
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
}
```

**Use when:** You want cache affinity (same URLs always go to the same backend for better cache hit rates).

The `consistent` parameter uses ketama consistent hashing, which minimizes redistribution when servers are added/removed.

### Algorithm Comparison

| Algorithm | Session Persistence | Even Distribution | Variable Request Time | Best For |
|-----------|--------------------|--------------------|----------------------|----------|
| Round-robin | No | Yes (uniform) | Poor | Homogeneous backends |
| Weighted | No | Yes (proportional) | Poor | Mixed-capacity backends |
| Least connections | No | Adapts to load | Good | Variable processing time |
| IP hash | Yes (by IP) | Depends on IPs | Poor | Sticky sessions |
| Random two | No | Good | Good | Large clusters |
| Hash | Yes (by key) | Depends on keys | Poor | Cache affinity |

---

## Health Checks

### Passive Health Checks (Open Source)

Nginx detects unhealthy backends based on failed request attempts.

```nginx
upstream backend {
    server 127.0.0.1:3000 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:3001 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:3002 max_fails=3 fail_timeout=30s;
}
```

**How it works:**
1. If a server fails `max_fails` times within `fail_timeout` seconds, it's marked unavailable
2. After `fail_timeout` seconds, Nginx sends one test request
3. If the test succeeds, the server is marked available again

**What counts as a failure:** Controlled by `proxy_next_upstream`:

```nginx
location / {
    proxy_pass http://backend;

    # What errors trigger failover to next upstream
    proxy_next_upstream error timeout http_502 http_503 http_504;

    # Limit retries across upstream servers
    proxy_next_upstream_tries 3;

    # Limit total time for all retries
    proxy_next_upstream_timeout 10s;
}
```

### Active Health Checks (Nginx Plus or Third-Party)

For open-source Nginx, use the `nginx_upstream_check_module` (third-party) or external health check tools.

```nginx
# Nginx Plus active health check
upstream backend {
    zone backend_zone 64k;    # Required for active checks

    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
}

server {
    location / {
        proxy_pass http://backend;
        health_check interval=5s fails=3 passes=2 uri=/health;
    }
}
```

### Application Health Endpoint Pattern

```nginx
# Backend should implement /health returning 200
location /health {
    proxy_pass http://backend;
    access_log off;              # Don't clutter logs
    proxy_connect_timeout 2s;    # Fail fast
    proxy_read_timeout 2s;
}
```

---

## Proxy Headers

### Essential Headers

Every reverse proxy should forward these headers so the backend knows about the original request.

```nginx
location / {
    proxy_pass http://backend;

    # Pass the original Host header
    proxy_set_header Host $host;

    # Client's real IP address
    proxy_set_header X-Real-IP $remote_addr;

    # Append to existing forwarded-for chain
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

    # Original protocol (http or https)
    proxy_set_header X-Forwarded-Proto $scheme;

    # Original port
    proxy_set_header X-Forwarded-Port $server_port;
}
```

### Header Reference

| Header | Variable | Purpose |
|--------|----------|---------|
| `Host` | `$host` | Original hostname from client request |
| `X-Real-IP` | `$remote_addr` | Client's IP address |
| `X-Forwarded-For` | `$proxy_add_x_forwarded_for` | Chain of proxy IPs |
| `X-Forwarded-Proto` | `$scheme` | Original protocol (http/https) |
| `X-Forwarded-Port` | `$server_port` | Original port number |
| `X-Request-ID` | `$request_id` | Unique request identifier for tracing |
| `Connection` | `""` | Clear hop-by-hop header for keepalive |

### Reusable Headers Include

Create a shared include file to avoid repetition:

```nginx
# /etc/nginx/includes/proxy-headers.conf
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port $server_port;
proxy_set_header X-Request-ID $request_id;
```

```nginx
# Usage in server/location blocks
location / {
    proxy_pass http://backend;
    include /etc/nginx/includes/proxy-headers.conf;
}
```

### Hiding Backend Headers

```nginx
location / {
    proxy_pass http://backend;

    # Remove headers that leak backend info
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    proxy_hide_header X-AspNet-Version;

    # Pass through headers that are hidden by default
    proxy_pass_header X-Custom-Header;
}
```

---

## WebSocket Proxy

WebSocket requires HTTP/1.1 with the Upgrade mechanism.

### Basic WebSocket Proxy

```nginx
# Map to handle Upgrade header
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name ws.example.com;

    location /ws/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;

        # WebSocket upgrade headers
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        # Standard proxy headers
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # Long timeouts for persistent connections
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

### WebSocket with SSL

```nginx
server {
    listen 443 ssl http2;
    server_name ws.example.com;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    location /ws/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

### Socket.IO Configuration

Socket.IO uses both WebSocket and HTTP long-polling:

```nginx
location /socket.io/ {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

    # Important for Socket.IO long-polling fallback
    proxy_buffering off;
    proxy_cache off;
}
```

---

## gRPC Proxy

### Basic gRPC Proxy

```nginx
upstream grpc_backend {
    server 127.0.0.1:50051;
}

server {
    listen 443 ssl http2;
    server_name grpc.example.com;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    location / {
        # Use grpc_pass for gRPC backends
        grpc_pass grpc://grpc_backend;

        # gRPC-specific headers
        grpc_set_header X-Real-IP $remote_addr;
        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

### gRPC with TLS to Backend

```nginx
location / {
    # grpcs:// for TLS-encrypted gRPC backends
    grpc_pass grpcs://grpc_backend;

    grpc_ssl_certificate     /etc/nginx/certs/client.pem;
    grpc_ssl_certificate_key /etc/nginx/certs/client.key;
    grpc_ssl_verify on;
    grpc_ssl_trusted_certificate /etc/nginx/certs/ca.pem;
}
```

### gRPC Error Handling

```nginx
location / {
    grpc_pass grpc://grpc_backend;

    # Intercept gRPC errors and return custom responses
    grpc_intercept_errors on;

    error_page 502 = /error502grpc;
}

location = /error502grpc {
    internal;
    default_type application/grpc;
    add_header grpc-status 14;
    add_header grpc-message "Backend unavailable";
    return 204;
}
```

---

## Proxy Caching

### Basic Cache Configuration

```nginx
http {
    # Define cache storage
    # levels=1:2       - Two-level directory hierarchy
    # keys_zone=cache:10m - 10MB shared memory for cache keys (~80,000 keys)
    # max_size=10g     - Maximum cache size on disk
    # inactive=60m     - Remove items not accessed in 60 minutes
    # use_temp_path=off - Write directly to cache dir (better performance)
    proxy_cache_path /var/cache/nginx
        levels=1:2
        keys_zone=app_cache:10m
        max_size=10g
        inactive=60m
        use_temp_path=off;

    server {
        listen 80;

        location / {
            proxy_pass http://backend;

            # Enable caching with the named zone
            proxy_cache app_cache;

            # Cache different status codes for different durations
            proxy_cache_valid 200 302 10m;
            proxy_cache_valid 404     1m;
            proxy_cache_valid any     5m;

            # Custom cache key
            proxy_cache_key "$scheme$request_method$host$request_uri";

            # Add header to show cache status (HIT, MISS, BYPASS, etc.)
            add_header X-Cache-Status $upstream_cache_status;
        }
    }
}
```

### Cache Bypass

```nginx
location / {
    proxy_pass http://backend;
    proxy_cache app_cache;
    proxy_cache_valid 200 10m;

    # Bypass cache when specific conditions are met
    proxy_cache_bypass $http_cache_control;   # Client sends Cache-Control
    proxy_cache_bypass $cookie_nocache;       # Cookie "nocache" is set
    proxy_cache_bypass $arg_nocache;          # Query param ?nocache=1

    # Don't store in cache under these conditions
    proxy_no_cache $http_pragma;              # Client sends Pragma: no-cache
    proxy_no_cache $arg_nocache;
}
```

### Stale Cache (Serve Old Content During Errors)

```nginx
location / {
    proxy_pass http://backend;
    proxy_cache app_cache;
    proxy_cache_valid 200 10m;

    # Serve stale content when backend is down or slow
    proxy_cache_use_stale error timeout updating
                          http_500 http_502 http_503 http_504;

    # Update cache in background while serving stale
    proxy_cache_background_update on;

    # Only one request refreshes cache, others get stale
    proxy_cache_lock on;
    proxy_cache_lock_timeout 5s;
}
```

### Cache Purge

```nginx
# Requires ngx_cache_purge module
location ~ /purge(/.*) {
    allow 127.0.0.1;
    deny all;
    proxy_cache_purge app_cache "$scheme$request_method$host$1";
}
```

Usage: `curl -X PURGE https://example.com/purge/api/data`

---

## Proxy Buffering

### Buffering On (Default)

Nginx reads the entire response from the backend, then sends it to the client. Good for fast backends with slow clients.

```nginx
location / {
    proxy_pass http://backend;

    # Buffering on (default)
    proxy_buffering on;

    # Size of the buffer for the first part of the response (headers)
    proxy_buffer_size 8k;

    # Number and size of buffers for the response body
    proxy_buffers 8 16k;

    # Maximum size that can be busy sending to client
    proxy_busy_buffers_size 32k;

    # Temporary files if response exceeds buffers
    proxy_temp_file_write_size 64k;
    proxy_max_temp_file_size 1024m;
}
```

### Buffering Off

Send data to client as soon as it arrives from backend. Required for streaming.

```nginx
location /stream/ {
    proxy_pass http://backend;

    # Disable buffering for streaming responses
    proxy_buffering off;

    # Also disable request body buffering
    proxy_request_buffering off;
}
```

**Disable buffering for:**
- Server-Sent Events (SSE)
- Long-polling
- Streaming downloads
- Real-time data feeds
- Large file downloads where you want immediate start

### Server-Sent Events (SSE) Configuration

```nginx
location /events/ {
    proxy_pass http://backend;
    proxy_http_version 1.1;

    # Critical for SSE
    proxy_buffering off;
    proxy_cache off;

    # Don't add compression (breaks streaming)
    proxy_set_header Accept-Encoding "";

    # Keep connection alive
    proxy_set_header Connection "";
    proxy_read_timeout 86400s;

    # Chunked transfer
    chunked_transfer_encoding on;
}
```

---

## Keepalive Connections

Reuse connections to upstream servers instead of opening a new TCP connection per request.

### Upstream Keepalive

```nginx
upstream backend {
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;

    # Keep up to 32 idle connections alive per worker process
    keepalive 32;

    # Maximum requests per keepalive connection before closing
    keepalive_requests 1000;

    # Idle timeout for keepalive connections
    keepalive_timeout 60s;
}

server {
    location / {
        proxy_pass http://backend;

        # Required for keepalive to work with upstream
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # Standard headers
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

**Important:** `proxy_http_version 1.1` and `proxy_set_header Connection ""` are both required. HTTP/1.0 uses `Connection: close` by default, which prevents keepalive.

### Keepalive Sizing

| Scenario | `keepalive` Value | Rationale |
|----------|-------------------|-----------|
| Low traffic | 8-16 | Minimal idle connections |
| Medium traffic | 32-64 | Balance memory vs connection reuse |
| High traffic | 128-256 | Maximize connection reuse |
| Microservices | 16-32 per upstream | Per-service pools |

---

## Timeout Configuration

### Complete Timeout Reference

```nginx
location / {
    proxy_pass http://backend;

    # Time to establish connection to backend
    proxy_connect_timeout 5s;    # Default: 60s

    # Time to wait for backend to start sending response
    proxy_read_timeout 60s;      # Default: 60s

    # Time allowed to send request body to backend
    proxy_send_timeout 60s;      # Default: 60s
}
```

### Timeout Guidelines

| Timeout | Typical Value | Use Case |
|---------|---------------|----------|
| `proxy_connect_timeout` | 3-5s | Fail fast if backend is unreachable |
| `proxy_read_timeout` | 30-60s | API responses, page rendering |
| `proxy_read_timeout` | 300s+ | File uploads, long reports |
| `proxy_read_timeout` | 3600s | WebSocket, SSE |
| `proxy_send_timeout` | 30-60s | Most applications |

### Per-Location Timeouts

```nginx
# Fast API endpoint
location /api/ {
    proxy_pass http://backend;
    proxy_connect_timeout 3s;
    proxy_read_timeout 10s;
}

# File upload endpoint
location /upload/ {
    proxy_pass http://backend;
    proxy_connect_timeout 5s;
    proxy_read_timeout 300s;
    client_max_body_size 100m;
}

# Report generation (slow)
location /reports/ {
    proxy_pass http://backend;
    proxy_connect_timeout 5s;
    proxy_read_timeout 600s;
}
```

---

## Real-World Configurations

### Node.js Application

```nginx
upstream nodejs {
    server 127.0.0.1:3000;
    keepalive 32;
}

server {
    listen 443 ssl http2;
    server_name app.example.com;

    ssl_certificate     /etc/letsencrypt/live/app.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;
    include /etc/nginx/includes/ssl-params.conf;

    # Security headers
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    # Proxy to Node.js
    location / {
        proxy_pass http://nodejs;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        include /etc/nginx/includes/proxy-headers.conf;

        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;

        # Handle large JWT tokens
        proxy_buffer_size 16k;
        proxy_buffers 4 32k;
    }

    # Serve static files directly (bypass Node.js)
    location /static/ {
        alias /var/www/app/public/;
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # WebSocket endpoint
    location /ws {
        proxy_pass http://nodejs;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 3600s;
    }
}
```

### Python/Gunicorn Application

```nginx
upstream gunicorn {
    server unix:/run/gunicorn/app.sock fail_timeout=10s;
    keepalive 16;
}

server {
    listen 443 ssl http2;
    server_name api.example.com;

    ssl_certificate     /etc/letsencrypt/live/api.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.example.com/privkey.pem;
    include /etc/nginx/includes/ssl-params.conf;

    client_max_body_size 10m;

    location / {
        proxy_pass http://gunicorn;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        include /etc/nginx/includes/proxy-headers.conf;

        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;

        proxy_buffer_size 8k;
        proxy_buffers 4 16k;
    }

    # Django static files
    location /static/ {
        alias /var/www/app/staticfiles/;
        expires 30d;
        access_log off;
    }

    # Django media uploads
    location /media/ {
        alias /var/www/app/media/;
        expires 7d;
    }
}
```

### Go Binary Application

```nginx
upstream goapp {
    server 127.0.0.1:8080;
    server 127.0.0.1:8081;
    keepalive 64;
}

server {
    listen 443 ssl http2;
    server_name service.example.com;

    ssl_certificate     /etc/letsencrypt/live/service.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/service.example.com/privkey.pem;
    include /etc/nginx/includes/ssl-params.conf;

    # Go apps typically serve their own static files
    location / {
        proxy_pass http://goapp;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        include /etc/nginx/includes/proxy-headers.conf;

        proxy_connect_timeout 3s;
        proxy_read_timeout 30s;

        # Go apps handle large payloads efficiently
        proxy_request_buffering off;
    }

    # Health check
    location /healthz {
        proxy_pass http://goapp;
        access_log off;
        proxy_connect_timeout 2s;
        proxy_read_timeout 2s;
    }
}
```

### PHP-FPM Application

```nginx
upstream php-fpm {
    server unix:/run/php/php8.3-fpm.sock;
}

server {
    listen 443 ssl http2;
    server_name site.example.com;

    ssl_certificate     /etc/letsencrypt/live/site.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/site.example.com/privkey.pem;
    include /etc/nginx/includes/ssl-params.conf;

    root /var/www/site/public;
    index index.php index.html;

    client_max_body_size 50m;

    # Try static file first, then directory, then PHP
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # PHP processing
    location ~ \.php$ {
        fastcgi_pass php-fpm;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_connect_timeout 5s;
        fastcgi_send_timeout 30s;
        fastcgi_read_timeout 30s;

        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }

    # Deny access to hidden files (except .well-known)
    location ~ /\.(?!well-known) {
        deny all;
    }

    # Static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
}
```

### Multiple Services on One Domain (Path-Based Routing)

```nginx
# Upstream definitions for each service
upstream api_service {
    server 127.0.0.1:3000;
    keepalive 32;
}

upstream admin_service {
    server 127.0.0.1:4000;
    keepalive 16;
}

upstream docs_service {
    server 127.0.0.1:5000;
    keepalive 8;
}

server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include /etc/nginx/includes/ssl-params.conf;

    # API service at /api/
    location /api/ {
        proxy_pass http://api_service/;    # Trailing / strips /api/ prefix
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        include /etc/nginx/includes/proxy-headers.conf;

        # API-specific settings
        proxy_read_timeout 30s;
        client_max_body_size 10m;

        # Rate limiting for API
        limit_req zone=api burst=20 nodelay;
    }

    # Admin panel at /admin/
    location /admin/ {
        proxy_pass http://admin_service/;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        include /etc/nginx/includes/proxy-headers.conf;

        # Restrict admin access by IP
        allow 10.0.0.0/8;
        allow 192.168.0.0/16;
        deny all;
    }

    # Documentation at /docs/
    location /docs/ {
        proxy_pass http://docs_service/;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        include /etc/nginx/includes/proxy-headers.conf;

        # Cache documentation pages
        proxy_cache app_cache;
        proxy_cache_valid 200 1h;
    }

    # Frontend SPA (catch-all)
    location / {
        root /var/www/frontend/dist;
        index index.html;
        try_files $uri $uri/ /index.html;
    }
}
```

### Proxy to Multiple Ports with Subdomain Routing

```nginx
# Alternative: subdomain-based routing
server {
    listen 443 ssl http2;
    server_name api.example.com;
    include /etc/nginx/includes/ssl-params.conf;

    location / {
        proxy_pass http://api_service;
        include /etc/nginx/includes/proxy-headers.conf;
    }
}

server {
    listen 443 ssl http2;
    server_name admin.example.com;
    include /etc/nginx/includes/ssl-params.conf;

    location / {
        proxy_pass http://admin_service;
        include /etc/nginx/includes/proxy-headers.conf;
    }
}
```
