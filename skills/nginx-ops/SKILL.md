---
name: nginx-ops
description: "Nginx configuration, reverse proxy, SSL/TLS, load balancing, and performance tuning. Use for: nginx, reverse proxy, load balancer, proxy_pass, ssl certificate, lets encrypt, web server, location block, upstream, server block, nginx config, certbot, hsts, gzip, rate limiting."
allowed-tools: "Read Write Bash"
related-skills: [docker-ops, security-ops, ci-cd-ops]
---

# Nginx Operations

Comprehensive Nginx configuration, reverse proxy patterns, SSL/TLS hardening, load balancing strategies, and performance optimization for production deployments.

---

## Configuration Architecture Quick Reference

```
nginx.conf (main context)
├── worker_processes auto;
├── worker_rlimit_nofile 65535;
│
├── events {                          # Connection handling
│   ├── worker_connections 4096;
│   └── multi_accept on;
│   }
│
├── http {                            # HTTP server settings
│   ├── include mime.types;
│   ├── default_type application/octet-stream;
│   ├── sendfile on;
│   ├── gzip on;
│   │
│   ├── upstream backend {            # Load balancing pool
│   │   └── server 127.0.0.1:3000;
│   │   }
│   │
│   ├── server {                      # Virtual host
│   │   ├── listen 443 ssl;
│   │   ├── server_name example.com;
│   │   │
│   │   ├── location / {              # Request routing
│   │   │   └── proxy_pass http://backend;
│   │   │   }
│   │   │
│   │   └── location /static/ {
│   │       └── root /var/www;
│   │       }
│   │   }
│   │
│   └── include /etc/nginx/conf.d/*.conf;
│   }
│
└── stream {                          # TCP/UDP proxying (optional)
    └── server { ... }
    }
```

### Directive Inheritance Rules

| Rule | Behavior | Example |
|------|----------|---------|
| **Inherit down** | Child blocks inherit parent directives | `gzip on;` in `http` applies to all `server` blocks |
| **Override** | Child directive overrides parent | `gzip off;` in `location` overrides `http`-level `gzip on;` |
| **Array directives** | NOT inherited - must be redeclared | `proxy_set_header` in `location` replaces ALL headers from `server` |
| **No upward** | Inner blocks never affect outer | `location`-level settings don't affect `server` |

**Critical:** Array-type directives (`proxy_set_header`, `add_header`, `proxy_hide_header`) are **completely replaced** when redefined in a child block, not merged. If you set one `proxy_set_header` in a `location`, you must redeclare ALL of them.

---

## Reverse Proxy Decision Tree

```
Need to proxy requests?
│
├─ Single backend server?
│  └─ Use simple proxy_pass
│     proxy_pass http://127.0.0.1:3000;
│
├─ Multiple backend servers?
│  │
│  ├─ Need session persistence?
│  │  ├─ By client IP → ip_hash
│  │  └─ By cookie    → sticky cookie (Nginx Plus)
│  │
│  ├─ Backends have unequal capacity?
│  │  └─ Use weight parameter
│  │     server backend1:3000 weight=3;
│  │     server backend2:3000 weight=1;
│  │
│  ├─ Want fewest active connections?
│  │  └─ least_conn
│  │
│  ├─ Want even random distribution?
│  │  └─ random two least_conn
│  │
│  └─ Default (no special needs)?
│     └─ round-robin (default, no directive needed)
│
├─ WebSocket connections?
│  └─ Add Upgrade + Connection headers
│     proxy_set_header Upgrade $http_upgrade;
│     proxy_set_header Connection "upgrade";
│
├─ gRPC backend?
│  └─ Use grpc_pass grpc://backend;
│
└─ Streaming / Server-Sent Events?
   └─ Disable buffering
      proxy_buffering off;
```

---

## SSL/TLS Quick Start

### Let's Encrypt with Certbot

```bash
# Install certbot
sudo apt install certbot python3-certbot-nginx   # Debian/Ubuntu
sudo dnf install certbot python3-certbot-nginx    # RHEL/Fedora

# Obtain certificate (nginx plugin - easiest)
sudo certbot --nginx -d example.com -d www.example.com

# Obtain certificate (webroot - no nginx restart)
sudo certbot certonly --webroot -w /var/www/html -d example.com

# Test auto-renewal
sudo certbot renew --dry-run
```

### Minimal Production SSL Config

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    # Certificates
    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    # Modern TLS (1.2 + 1.3)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # HSTS (2 years)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # Session caching
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    root /var/www/example.com;
    index index.html;
}

# HTTP → HTTPS redirect
server {
    listen 80;
    server_name example.com www.example.com;
    return 301 https://example.com$request_uri;
}
```

---

## Location Matching Order

Nginx evaluates `location` blocks in a specific priority order, **not** in the order they appear in the config file.

| Priority | Modifier | Type | Example | Behavior |
|----------|----------|------|---------|----------|
| 1 | `=` | Exact match | `location = /favicon.ico` | Stops search immediately on match |
| 2 | `^~` | Prefix (no regex) | `location ^~ /static/` | Stops search if this prefix matches (skips regex) |
| 3 | `~` | Regex (case-sensitive) | `location ~ \.php$` | First matching regex wins |
| 3 | `~*` | Regex (case-insensitive) | `location ~* \.(jpg\|png)$` | First matching regex wins |
| 4 | _(none)_ | Prefix | `location /api/` | Longest prefix wins (but only after regex check) |

### Evaluation Algorithm

1. Check all **prefix** locations, remember the **longest** match
2. If longest match has `^~` modifier → use it, stop
3. Check **regex** locations in config-file order → first match wins
4. If no regex matches → use the longest prefix from step 1
5. `= /path` is checked first and wins immediately if matched

### Example

```nginx
location = /             { }  # Only exact "/"
location /               { }  # Catch-all prefix
location /api/           { }  # Prefix: /api/*
location ^~ /static/     { }  # Prefix, skip regex: /static/*
location ~ \.php$        { }  # Regex: any .php file
location ~* \.(gif|jpg)$ { }  # Case-insensitive regex: images
```

| Request URI | Matched Location | Why |
|-------------|-----------------|-----|
| `/` | `= /` | Exact match (priority 1) |
| `/index.html` | `/` | Longest prefix, no regex match |
| `/api/users` | `/api/` | Longest prefix, no regex match |
| `/static/logo.png` | `^~ /static/` | `^~` skips regex check |
| `/app/index.php` | `~ \.php$` | Regex beats prefix |
| `/photos/cat.jpg` | `~* \.(gif\|jpg)$` | Regex beats prefix |

---

## Common Configurations

### SPA Routing (React, Vue, Angular)

```nginx
server {
    listen 80;
    server_name app.example.com;

    root /var/www/app/dist;
    index index.html;

    # Serve static files directly, fall back to index.html for SPA routes
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Cache static assets aggressively
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
```

### WebSocket Proxy

```nginx
location /ws/ {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_read_timeout 86400s;  # Keep WebSocket alive for 24h
    proxy_send_timeout 86400s;
}
```

### Rate Limiting

```nginx
# Define zone: 10MB shared memory, 10 requests/second per IP
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

server {
    location /api/ {
        # Allow burst of 20, process excess without delay up to burst
        limit_req zone=api burst=20 nodelay;
        limit_req_status 429;

        proxy_pass http://backend;
    }
}
```

### Gzip Compression

```nginx
http {
    gzip on;
    gzip_comp_level 5;          # Balance CPU vs compression (1-9)
    gzip_min_length 256;        # Don't compress tiny responses
    gzip_vary on;               # Vary: Accept-Encoding header
    gzip_proxied any;           # Compress proxied responses too
    gzip_types
        text/plain
        text/css
        text/javascript
        application/javascript
        application/json
        application/xml
        application/xml+rss
        image/svg+xml;
}
```

### Static File Serving

```nginx
location /static/ {
    alias /var/www/static/;     # Note: alias, not root (includes /static/ path)
    expires 30d;
    add_header Cache-Control "public, no-transform";

    # Disable access log for static files
    access_log off;

    # Enable open file cache
    open_file_cache max=1000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
}
```

### CORS Headers

```nginx
location /api/ {
    # CORS headers
    add_header Access-Control-Allow-Origin "https://app.example.com" always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
    add_header Access-Control-Max-Age 86400 always;

    # Handle preflight requests
    if ($request_method = OPTIONS) {
        return 204;
    }

    proxy_pass http://backend;
}
```

---

## Docker Patterns

### Nginx as Reverse Proxy in Docker Compose

```yaml
# docker-compose.yml
services:
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
    depends_on:
      - app
    networks:
      - webnet

  app:
    build: .
    expose:
      - "3000"    # Internal only, not published to host
    networks:
      - webnet

networks:
  webnet:
```

```nginx
# nginx.conf for docker-compose (use service name as hostname)
upstream app_backend {
    server app:3000;    # Docker DNS resolves service name
}

server {
    listen 80;
    location / {
        proxy_pass http://app_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Multi-Stage Build with Static Assets

```dockerfile
# Stage 1: Build frontend
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2: Serve with nginx
FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

```nginx
# nginx.conf for containerized SPA
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    # SPA routing
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }

    # Cache busted assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
```

---

## Common Gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| **Trailing slash in `proxy_pass`** | `proxy_pass http://backend` keeps `/api/users` as-is; `proxy_pass http://backend/` strips the matched `location` prefix | Be intentional: with `/` to strip prefix, without to preserve |
| **Missing proxy headers** | Backend sees nginx's IP, not the client's. Breaks auth, logging, and geo detection | Always set `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`, and `Host` |
| **Buffer size errors (502)** | Large headers (cookies, JWTs) exceed default buffer sizes | Increase `proxy_buffer_size 8k;` and `proxy_buffers 4 16k;` |
| **`worker_connections` too low** | Default is 512 or 1024; each client uses 2 connections (client + upstream) | Set `worker_connections 4096;` and raise `worker_rlimit_nofile` |
| **`try_files` with `proxy_pass`** | `try_files` and `proxy_pass` in the same `location` don't work as expected | Use `try_files $uri @backend;` with a named location for proxy |
| **"if is evil"** | `if` inside `location` creates an implicit nested location, breaking directives | Use `map` for variable-based logic; reserve `if` for `return`/`rewrite` only |
| **Resolver for dynamic upstreams** | Variables in `proxy_pass` (e.g., `$upstream`) bypass startup DNS resolution | Add `resolver 127.0.0.11 valid=30s;` (Docker) or `resolver 1.1.1.1;` |
| **Missing `index` directive** | Returns 403 Forbidden when accessing a directory instead of index file | Add `index index.html;` in `server` or `location` block |
| **Permission denied on socket** | Nginx worker can't read the upstream Unix socket | Ensure nginx user is in the socket's group; `chmod 660` the socket |
| **Duplicate `Content-Encoding` with gzip** | Upstream already compresses + nginx gzip double-compresses | Use `gzip_proxied` carefully or `proxy_set_header Accept-Encoding "";` |
| **`add_header` not inherited** | Adding ANY `add_header` in a `location` discards ALL parent `add_header` directives | Redeclare all headers in the child block, or use `include` for shared headers |
| **`alias` vs `root` confusion** | `root` appends the location path; `alias` replaces it. `/img/` + `root /data` = `/data/img/`; `alias /data/` = `/data/` | Use `alias` when location path shouldn't appear in filesystem path |

---

## Reference Files

| File | Contents | Lines |
|------|----------|-------|
| [reverse-proxy.md](references/reverse-proxy.md) | Upstream blocks, load balancing, proxy caching, WebSocket/gRPC, timeouts, real-world configs | ~650 |
| [ssl-security.md](references/ssl-security.md) | TLS config, Let's Encrypt, HSTS, OCSP, security headers, rate limiting, mTLS | ~550 |
| [performance.md](references/performance.md) | Worker tuning, compression, caching, HTTP/2+3, static files, monitoring | ~550 |

---

## See Also

- **docker-ops** - Container orchestration, docker-compose patterns
- **security-ops** - Application security, authentication patterns
- **ci-cd-ops** - Deployment pipelines, zero-downtime deploys
- [Nginx official docs](https://nginx.org/en/docs/)
- [Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org/)
- [Nginx Config Generator](https://www.digitalocean.com/community/tools/nginx)
