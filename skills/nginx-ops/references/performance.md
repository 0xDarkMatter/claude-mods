# Performance Reference

Comprehensive guide to Nginx performance optimization: worker tuning, connection handling, compression, caching, HTTP/2 and HTTP/3, static file serving, and monitoring.

---

## Table of Contents

1. [Worker Configuration](#worker-configuration)
2. [Event Model](#event-model)
3. [Connection Handling](#connection-handling)
4. [Sendfile and TCP Optimizations](#sendfile-and-tcp-optimizations)
5. [Compression](#compression)
6. [Open File Cache](#open-file-cache)
7. [Static File Serving](#static-file-serving)
8. [Proxy Caching](#proxy-caching)
9. [FastCGI Caching](#fastcgi-caching)
10. [Microcaching](#microcaching)
11. [HTTP/2](#http2)
12. [HTTP/3 (QUIC)](#http3-quic)
13. [Connection Draining](#connection-draining)
14. [Monitoring](#monitoring)

---

## Worker Configuration

### Worker Processes

```nginx
# Auto-detect CPU cores (recommended)
worker_processes auto;

# Or set explicitly (match CPU core count)
# worker_processes 4;

# Pin workers to specific CPUs (optional, advanced)
worker_cpu_affinity auto;
# Or manually: worker_cpu_affinity 0001 0010 0100 1000;
```

### Worker Connections

```nginx
events {
    # Maximum simultaneous connections per worker
    # Total capacity = worker_processes * worker_connections
    worker_connections 4096;

    # Accept multiple connections at once
    multi_accept on;
}
```

### File Descriptor Limits

Each connection uses at least one file descriptor (two when proxying).

```nginx
# Maximum open files per worker process
# Should be >= 2 * worker_connections
worker_rlimit_nofile 65535;
```

Also set OS-level limits:

```bash
# /etc/security/limits.conf
nginx soft nofile 65535
nginx hard nofile 65535

# Or /etc/systemd/system/nginx.service.d/override.conf
[Service]
LimitNOFILE=65535
```

### Sizing Guidelines

| Traffic Level | `worker_processes` | `worker_connections` | `worker_rlimit_nofile` | Total Capacity |
|--------------|-------------------|---------------------|----------------------|----------------|
| Low (< 1K rps) | auto (2-4) | 1024 | 4096 | 2K-4K connections |
| Medium (1K-10K rps) | auto (4-8) | 4096 | 16384 | 16K-32K connections |
| High (10K-100K rps) | auto (8-16) | 8192 | 65535 | 64K-128K connections |

---

## Event Model

### Linux (epoll)

```nginx
events {
    use epoll;
    worker_connections 4096;
    multi_accept on;
}
```

`epoll` is the most efficient event model on Linux, using O(1) event notification.

### BSD/macOS (kqueue)

```nginx
events {
    use kqueue;
    worker_connections 4096;
    multi_accept on;
}
```

### Event Model Comparison

| Model | OS | Scalability | Notes |
|-------|-----|-------------|-------|
| `epoll` | Linux 2.6+ | Excellent | Default and best for Linux |
| `kqueue` | FreeBSD, macOS | Excellent | Default for BSD systems |
| `select` | All | Poor | Legacy, limited to 1024 fds |
| `poll` | All | Fair | Better than select, still O(n) |

Nginx auto-selects the best available model. Explicit `use` is optional but recommended for clarity.

---

## Connection Handling

### Keepalive Configuration

```nginx
http {
    # Client-facing keepalive
    keepalive_timeout 65s;        # Close idle connections after 65s
    keepalive_requests 1000;      # Max requests per keepalive connection

    # Reset timed-out connections (free resources faster)
    reset_timedout_connection on;

    # Client timeouts
    client_body_timeout 12s;      # Time to receive request body
    client_header_timeout 12s;    # Time to receive request headers
    send_timeout 10s;             # Time between successive writes to client

    # Limit request/header sizes
    client_max_body_size 10m;     # Max upload size
    client_body_buffer_size 16k;  # Buffer for request body
    client_header_buffer_size 1k; # Buffer for request headers
    large_client_header_buffers 4 8k;  # For large headers (cookies, etc.)
}
```

### Keepalive Tuning

| Scenario | `keepalive_timeout` | `keepalive_requests` | Rationale |
|----------|--------------------|--------------------|-----------|
| API server | 30-60s | 1000-10000 | Frequent requests, reuse connections |
| Static files | 15-30s | 100-500 | Quick downloads, then disconnect |
| WebSocket | 3600s+ | N/A | Long-lived connections |
| High-traffic | 15-30s | 100 | Free connections sooner |

---

## Sendfile and TCP Optimizations

### sendfile

Transfers files directly in kernel space without copying to userspace. Significant performance improvement for static files.

```nginx
http {
    # Enable kernel-level file transfer
    sendfile on;

    # Send headers and beginning of file in one packet
    tcp_nopush on;

    # Disable Nagle algorithm (send small packets immediately)
    tcp_nodelay on;
}
```

### How They Work Together

| Directive | Purpose | When Active |
|-----------|---------|-------------|
| `sendfile on` | Zero-copy file transfer via kernel | Serving static files |
| `tcp_nopush on` | Batch headers + file data into full packets | With sendfile, before last packet |
| `tcp_nodelay on` | Send last packet immediately (no 200ms Nagle delay) | After tcp_nopush releases last packet |

The combination `sendfile on; tcp_nopush on; tcp_nodelay on;` is optimal:
1. `sendfile` transfers the file efficiently
2. `tcp_nopush` fills packets completely for the bulk of the transfer
3. `tcp_nodelay` sends the final partial packet without waiting

---

## Compression

### Gzip Configuration

```nginx
http {
    # Enable gzip compression
    gzip on;

    # Compression level (1-9, higher = smaller but more CPU)
    # 5-6 is a good balance
    gzip_comp_level 5;

    # Minimum response size to compress (skip tiny responses)
    gzip_min_length 256;

    # Add Vary: Accept-Encoding header
    gzip_vary on;

    # Compress proxied responses
    gzip_proxied any;

    # MIME types to compress (text/html is always compressed)
    gzip_types
        text/plain
        text/css
        text/javascript
        text/xml
        application/javascript
        application/json
        application/xml
        application/xml+rss
        application/atom+xml
        application/vnd.ms-fontobject
        font/opentype
        image/svg+xml
        image/x-icon;

    # Disable gzip for old browsers (IE6)
    gzip_disable "msie6";

    # Buffer size for gzip
    gzip_buffers 16 8k;
}
```

### Gzip Level Comparison

| Level | Compression Ratio | CPU Usage | Best For |
|-------|------------------|-----------|----------|
| 1 | Low (~60%) | Minimal | Very high traffic, CPU-bound |
| 3-4 | Medium (~70%) | Low | Good default for most sites |
| 5-6 | Good (~75%) | Moderate | Recommended balance |
| 9 | Maximum (~78%) | High | Rarely worth it over level 6 |

The diminishing returns above level 5-6 are significant: going from level 5 to 9 might save 3% more bytes but costs 3-4x more CPU.

### Brotli Compression

Brotli achieves 15-20% better compression than gzip at similar CPU cost. Requires the `ngx_brotli` module.

```nginx
# Requires: ngx_brotli module
# Install: https://github.com/google/ngx_brotli

http {
    # Brotli dynamic compression
    brotli on;
    brotli_comp_level 6;
    brotli_min_length 256;
    brotli_types
        text/plain
        text/css
        text/javascript
        application/javascript
        application/json
        application/xml
        image/svg+xml;

    # Serve pre-compressed .br files if available
    brotli_static on;

    # Keep gzip as fallback (not all clients support brotli)
    gzip on;
    gzip_comp_level 5;
    gzip_types text/plain text/css application/javascript application/json;
}
```

### Pre-Compressed Files

Serve pre-compressed files to avoid runtime compression overhead.

```nginx
http {
    # Serve .gz files if they exist
    gzip_static on;

    # Serve .br files if they exist (requires brotli module)
    brotli_static on;
}
```

Build step to pre-compress:

```bash
# Pre-compress static assets during build
fd -e js -e css -e html -e svg -e json dist/ -x gzip -k -9 {}
fd -e js -e css -e html -e svg -e json dist/ -x brotli -k {}
```

---

## Open File Cache

Cache file descriptors, metadata, and lookup results to reduce filesystem calls.

```nginx
http {
    # Cache up to 1000 file descriptors, remove unused after 20s
    open_file_cache max=1000 inactive=20s;

    # How often to check if cached info is still valid
    open_file_cache_valid 30s;

    # Minimum number of accesses before caching
    open_file_cache_min_uses 2;

    # Cache file lookup errors (e.g., file not found)
    open_file_cache_errors on;
}
```

### When to Use

| Scenario | Recommended |
|----------|-------------|
| Serving many static files | Yes |
| Reverse proxy only | No (not needed) |
| High-traffic static site | Yes, increase max |
| Few large files | Marginal benefit |

---

## Static File Serving

### Optimized Static File Configuration

```nginx
server {
    listen 443 ssl http2;
    server_name static.example.com;

    root /var/www/static;

    # Performance fundamentals
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    # File descriptor caching
    open_file_cache max=2000 inactive=30s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # Immutable hashed assets (e.g., app.a3b4c5d6.js)
    location ~* \.[a-f0-9]{8,}\.(js|css|png|jpg|jpeg|gif|svg|woff2?)$ {
        expires max;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # Regular static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }

    # HTML files (shorter cache, must revalidate)
    location ~* \.html$ {
        expires 1h;
        add_header Cache-Control "public, must-revalidate";
    }

    # Enable ETag for cache validation
    etag on;
}
```

### Cache-Control Header Reference

| Directive | Purpose | Use Case |
|-----------|---------|----------|
| `public` | Any cache can store | Static assets |
| `private` | Only browser can store | User-specific content |
| `no-cache` | Must revalidate before using | HTML pages |
| `no-store` | Don't cache at all | Sensitive data |
| `max-age=N` | Cache for N seconds | All cacheable content |
| `immutable` | Never changes (skip revalidation) | Hashed filenames |
| `must-revalidate` | Don't serve stale, even if disconnected | Critical content |
| `stale-while-revalidate=N` | Serve stale while fetching fresh | UX optimization |

### Expires Directive Shortcuts

```nginx
# Specific durations
expires 30d;              # 30 days
expires 1h;               # 1 hour
expires 30m;              # 30 minutes
expires max;              # Far future (practically forever)
expires off;              # Don't add Expires header
expires -1;               # Already expired (forces revalidation)
expires epoch;            # Set to Unix epoch (Jan 1, 1970)
expires modified +24h;   # 24h after file modification time
```

---

## Proxy Caching

### Production Proxy Cache Configuration

```nginx
http {
    # Define cache storage
    proxy_cache_path /var/cache/nginx/proxy
        levels=1:2
        keys_zone=proxy_cache:20m      # 20MB metadata (~160K keys)
        max_size=20g                    # 20GB max disk usage
        inactive=7d                    # Remove unused items after 7 days
        use_temp_path=off              # Write directly to cache dir
        manager_files=100              # Files to process per cache manager cycle
        manager_threshold=200ms;       # Max time for cache manager cycle

    server {
        location / {
            proxy_pass http://backend;

            # Enable caching
            proxy_cache proxy_cache;

            # Cache key (determines what is considered a unique response)
            proxy_cache_key "$scheme$request_method$host$request_uri";

            # Cache durations by status code
            proxy_cache_valid 200 301 302 1h;
            proxy_cache_valid 404         1m;

            # Serve stale content during backend errors
            proxy_cache_use_stale error timeout updating
                                  http_500 http_502 http_503 http_504;

            # Background refresh
            proxy_cache_background_update on;

            # Prevent thundering herd (only one request refreshes)
            proxy_cache_lock on;
            proxy_cache_lock_timeout 5s;
            proxy_cache_lock_age 5s;

            # Skip caching for logged-in users
            proxy_cache_bypass $cookie_session $http_authorization;
            proxy_no_cache $cookie_session $http_authorization;

            # Show cache status in response header
            add_header X-Cache-Status $upstream_cache_status always;

            # Minimum uses before caching (prevent caching one-time requests)
            proxy_cache_min_uses 2;
        }
    }
}
```

### Cache Status Values

The `$upstream_cache_status` variable contains:

| Value | Meaning |
|-------|---------|
| `HIT` | Served from cache |
| `MISS` | Not in cache, fetched from backend |
| `BYPASS` | Cache was bypassed (proxy_cache_bypass matched) |
| `EXPIRED` | Cache entry expired, fetched fresh from backend |
| `STALE` | Served stale (backend unavailable, using proxy_cache_use_stale) |
| `UPDATING` | Stale entry served while background update in progress |
| `REVALIDATED` | Cache entry was revalidated with If-Modified-Since |

### Cache Key Design

```nginx
# Default: includes method, scheme, host, and URI
proxy_cache_key "$scheme$request_method$host$request_uri";

# Include query parameters explicitly
proxy_cache_key "$host$request_uri$is_args$args";

# Include a custom header (e.g., API version)
proxy_cache_key "$host$request_uri$http_x_api_version";

# Include cookie for per-user caching (use carefully!)
proxy_cache_key "$host$request_uri$cookie_lang";

# Separate cache for mobile vs desktop
proxy_cache_key "$host$request_uri$http_user_agent_class";
```

---

## FastCGI Caching

For PHP-FPM and other FastCGI applications.

```nginx
http {
    # FastCGI cache zone
    fastcgi_cache_path /var/cache/nginx/fastcgi
        levels=1:2
        keys_zone=fcgi_cache:10m
        max_size=5g
        inactive=60m
        use_temp_path=off;

    server {
        # Skip cache for logged-in users and POST requests
        set $skip_cache 0;

        # Don't cache POST requests
        if ($request_method = POST) {
            set $skip_cache 1;
        }

        # Don't cache URLs with query strings
        if ($query_string != "") {
            set $skip_cache 1;
        }

        # Don't cache admin pages (WordPress example)
        if ($request_uri ~* "/wp-admin/|/wp-login.php") {
            set $skip_cache 1;
        }

        # Don't cache logged-in users (WordPress)
        if ($http_cookie ~* "wordpress_logged_in") {
            set $skip_cache 1;
        }

        location ~ \.php$ {
            fastcgi_pass php-fpm;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
            include fastcgi_params;

            # Enable FastCGI cache
            fastcgi_cache fcgi_cache;
            fastcgi_cache_key "$scheme$request_method$host$request_uri";
            fastcgi_cache_valid 200 60m;
            fastcgi_cache_valid 301 302 10m;
            fastcgi_cache_valid 404 1m;

            # Skip cache conditions
            fastcgi_cache_bypass $skip_cache;
            fastcgi_no_cache $skip_cache;

            # Serve stale during errors
            fastcgi_cache_use_stale error timeout updating
                                    http_500 http_502 http_503;
            fastcgi_cache_background_update on;
            fastcgi_cache_lock on;

            # Cache status header
            add_header X-FastCGI-Cache $upstream_cache_status;
        }
    }
}
```

---

## Microcaching

Cache dynamic content for very short durations (1-5 seconds) to absorb traffic spikes. Even a 1-second cache dramatically reduces backend load under high traffic.

```nginx
http {
    proxy_cache_path /var/cache/nginx/micro
        levels=1:2
        keys_zone=micro_cache:5m
        max_size=1g
        inactive=1m
        use_temp_path=off;

    server {
        location / {
            proxy_pass http://backend;

            # Enable microcaching
            proxy_cache micro_cache;
            proxy_cache_valid 200 1s;    # Cache for just 1 second

            # Serve stale while updating
            proxy_cache_use_stale updating error timeout;
            proxy_cache_background_update on;

            # Only one request triggers backend fetch
            proxy_cache_lock on;
            proxy_cache_lock_timeout 1s;

            # Don't cache if backend sets Cache-Control: no-cache
            proxy_cache_bypass $http_cache_control;

            # Don't cache for authenticated users
            proxy_cache_bypass $cookie_session;
            proxy_no_cache $cookie_session;

            add_header X-Cache-Status $upstream_cache_status;
        }
    }
}
```

### Microcaching Impact

| Requests/sec | Without Cache | 1s Microcache | Reduction |
|-------------|---------------|---------------|-----------|
| 100 | 100 backend hits/s | 1 backend hit/s | 99% |
| 1,000 | 1,000 backend hits/s | 1 backend hit/s | 99.9% |
| 10,000 | 10,000 backend hits/s | 1 backend hit/s | 99.99% |

---

## HTTP/2

### Basic HTTP/2 Configuration

```nginx
server {
    # http2 directive (Nginx 1.25.1+)
    listen 443 ssl;
    http2 on;

    # For older Nginx versions:
    # listen 443 ssl http2;

    server_name example.com;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    # HTTP/2 specific settings
    http2_max_concurrent_streams 128;
    http2_recv_buffer_size 256k;
}
```

### HTTP/2 Benefits

| Feature | HTTP/1.1 | HTTP/2 |
|---------|---------|--------|
| Multiplexing | 6 connections per domain | Unlimited streams on 1 connection |
| Header compression | None | HPACK compression |
| Server push | Not possible | Supported (but deprecated) |
| Stream priority | N/A | Priority hints |
| Binary protocol | Text-based | Binary framing |

### HTTP/2 Server Push (Deprecated)

Server push was removed from Chrome and is generally considered deprecated. Use `<link rel="preload">` or `103 Early Hints` instead.

```nginx
# 103 Early Hints (modern alternative to server push)
location / {
    # Send early hints before the main response
    add_header Link "</style.css>; rel=preload; as=style" early;
    add_header Link "</app.js>; rel=preload; as=script" early;

    proxy_pass http://backend;
}
```

---

## HTTP/3 (QUIC)

HTTP/3 uses QUIC (UDP-based transport) for faster connection establishment and better performance on lossy networks.

### Basic HTTP/3 Configuration

Requires Nginx 1.25.0+ compiled with QUIC support, or nginx-quic branch.

```nginx
server {
    # Standard HTTPS (HTTP/1.1 and HTTP/2)
    listen 443 ssl;
    http2 on;

    # HTTP/3 via QUIC (UDP)
    listen 443 quic reuseport;

    server_name example.com;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    # Required: TLS 1.3 only for QUIC
    ssl_protocols TLSv1.2 TLSv1.3;

    # Advertise HTTP/3 support via Alt-Svc header
    add_header Alt-Svc 'h3=":443"; ma=86400' always;

    # QUIC-specific settings
    quic_retry on;                 # Enable address validation
    ssl_early_data on;             # Enable 0-RTT (with replay protection)

    # Required for QUIC
    ssl_session_tickets on;
}
```

### Firewall Configuration for QUIC

```bash
# Allow UDP port 443 for QUIC
sudo iptables -A INPUT -p udp --dport 443 -j ACCEPT

# Or with firewalld
sudo firewall-cmd --permanent --add-port=443/udp
sudo firewall-cmd --reload

# Or with ufw
sudo ufw allow 443/udp
```

### HTTP/3 Benefits

| Feature | HTTP/2 (TCP) | HTTP/3 (QUIC) |
|---------|-------------|---------------|
| Connection setup | 2-3 RTT (TCP + TLS) | 0-1 RTT |
| Head-of-line blocking | Yes (TCP level) | No (per-stream) |
| Connection migration | No (IP changes break) | Yes (connection ID) |
| Packet loss handling | All streams blocked | Only affected stream |
| 0-RTT resumption | TLS 1.3 only | Built-in |

---

## Connection Draining

### Graceful Reload

```bash
# Graceful reload: new workers start, old workers finish existing requests
sudo nginx -s reload

# What happens:
# 1. Master process reads new config
# 2. Starts new worker processes with new config
# 3. Old workers stop accepting new connections
# 4. Old workers finish processing existing requests
# 5. Old workers exit
```

### Worker Shutdown Timeout

```nginx
# Maximum time for old workers to finish requests during reload
# After this timeout, old workers are forcefully terminated
worker_shutdown_timeout 30s;
```

### Zero-Downtime Deployment

```bash
# 1. Deploy new application code
# 2. Signal nginx to reload config
sudo nginx -t && sudo nginx -s reload

# Or with systemd
sudo nginx -t && sudo systemctl reload nginx
```

### Upstream Draining

```nginx
upstream backend {
    server 127.0.0.1:3000;

    # Mark server as draining (finish existing, no new)
    server 127.0.0.1:3001 down;    # Use 'down' to stop new traffic

    server 127.0.0.1:3002;
}
```

---

## Monitoring

### stub_status Module

```nginx
server {
    listen 8080;

    # Restrict to internal access
    allow 127.0.0.1;
    allow 10.0.0.0/8;
    deny all;

    location /nginx_status {
        stub_status;
    }
}
```

Output:

```
Active connections: 291
server accepts handled requests
 16630948 16630948 31070465
Reading: 6 Writing: 179 Waiting: 106
```

| Metric | Meaning |
|--------|---------|
| Active connections | Current active client connections (including waiting) |
| accepts | Total accepted connections |
| handled | Total handled connections (should equal accepts) |
| requests | Total client requests |
| Reading | Connections where nginx is reading the request header |
| Writing | Connections where nginx is writing response to client |
| Waiting | Idle keepalive connections |

### Request Timing Variables

Use these in log formats for performance monitoring.

```nginx
http {
    log_format performance '$remote_addr - $remote_user [$time_local] '
                           '"$request" $status $body_bytes_sent '
                           '"$http_referer" "$http_user_agent" '
                           'rt=$request_time '
                           'urt=$upstream_response_time '
                           'uct=$upstream_connect_time '
                           'uht=$upstream_header_time '
                           'cs=$upstream_cache_status';

    access_log /var/log/nginx/performance.log performance;
}
```

### Timing Variable Reference

| Variable | Meaning |
|----------|---------|
| `$request_time` | Total time from first byte read to last byte sent (seconds, ms resolution) |
| `$upstream_response_time` | Time from establishing upstream connection to receiving last byte |
| `$upstream_connect_time` | Time to establish connection to upstream server |
| `$upstream_header_time` | Time from connection to receiving response headers from upstream |
| `$upstream_cache_status` | HIT, MISS, BYPASS, EXPIRED, STALE, UPDATING, REVALIDATED |

### Conditional Logging

```nginx
# Only log slow requests (> 1 second)
map $request_time $loggable_slow {
    ~^[0-9]*\.[0-9]$  0;    # < 1 second
    default            1;    # >= 1 second
}

access_log /var/log/nginx/slow.log performance if=$loggable_slow;

# Don't log health checks
map $request_uri $loggable {
    /health     0;
    /ping       0;
    default     1;
}

access_log /var/log/nginx/access.log combined if=$loggable;
```

### JSON Log Format

Easier to parse with log aggregation tools (ELK, Loki, etc.).

```nginx
log_format json_combined escape=json
    '{'
        '"time":"$time_iso8601",'
        '"remote_addr":"$remote_addr",'
        '"request_method":"$request_method",'
        '"request_uri":"$request_uri",'
        '"status":$status,'
        '"body_bytes_sent":$body_bytes_sent,'
        '"request_time":$request_time,'
        '"upstream_response_time":"$upstream_response_time",'
        '"upstream_cache_status":"$upstream_cache_status",'
        '"http_referrer":"$http_referer",'
        '"http_user_agent":"$http_user_agent",'
        '"server_name":"$server_name"'
    '}';

access_log /var/log/nginx/access.json json_combined;
```

### Integration with Prometheus

Use the `nginx-prometheus-exporter` for Prometheus/Grafana monitoring.

```bash
# Run nginx-prometheus-exporter
./nginx-prometheus-exporter -nginx.scrape-uri=http://127.0.0.1:8080/nginx_status
```

Or use the VTS (Virtual Host Traffic Status) module for more detailed metrics:

```nginx
# Requires ngx_http_vhost_traffic_status_module
http {
    vhost_traffic_status_zone;

    server {
        listen 8080;

        location /status {
            vhost_traffic_status_display;
            vhost_traffic_status_display_format prometheus;
        }
    }
}
```

### Quick Health Check Script

```bash
#!/bin/bash
# nginx-health.sh - Quick nginx health check

NGINX_STATUS="http://127.0.0.1:8080/nginx_status"
RESPONSE=$(curl -s "$NGINX_STATUS")

ACTIVE=$(echo "$RESPONSE" | rg -o 'Active connections: (\d+)' -r '$1')
WAITING=$(echo "$RESPONSE" | rg -o 'Waiting: (\d+)' -r '$1')
READING=$(echo "$RESPONSE" | rg -o 'Reading: (\d+)' -r '$1')
WRITING=$(echo "$RESPONSE" | rg -o 'Writing: (\d+)' -r '$1')

echo "Active: $ACTIVE | Reading: $READING | Writing: $WRITING | Waiting: $WAITING"

# Alert if active connections exceed threshold
if [ "$ACTIVE" -gt 5000 ]; then
    echo "WARNING: High connection count: $ACTIVE"
fi
```
