# SSL/TLS & Security Reference

Comprehensive guide to Nginx SSL/TLS configuration, Let's Encrypt automation, security headers, rate limiting, access control, and mutual TLS.

---

## Table of Contents

1. [TLS Configuration](#tls-configuration)
2. [Let's Encrypt & Certbot](#lets-encrypt--certbot)
3. [Certificate Management](#certificate-management)
4. [HSTS](#hsts)
5. [OCSP Stapling](#ocsp-stapling)
6. [Security Headers](#security-headers)
7. [Rate Limiting](#rate-limiting)
8. [IP Restrictions](#ip-restrictions)
9. [Basic Authentication](#basic-authentication)
10. [Mutual TLS (mTLS)](#mutual-tls-mtls)
11. [HTTP to HTTPS Redirect](#http-to-https-redirect)

---

## TLS Configuration

### Modern Configuration (TLS 1.3 Only)

For services where all clients support TLS 1.3 (modern browsers, API clients you control).

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    # TLS 1.3 only
    ssl_protocols TLSv1.3;

    # TLS 1.3 ciphers are not configurable via ssl_ciphers
    # They are negotiated automatically:
    # TLS_AES_256_GCM_SHA384
    # TLS_CHACHA20_POLY1305_SHA256
    # TLS_AES_128_GCM_SHA256

    ssl_prefer_server_ciphers off;
}
```

### Intermediate Configuration (TLS 1.2 + 1.3)

Recommended for most production sites. Compatible with all modern browsers.

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    # TLS 1.2 and 1.3
    ssl_protocols TLSv1.2 TLSv1.3;

    # Cipher suite for TLS 1.2 (TLS 1.3 ciphers are automatic)
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # DH parameters for DHE ciphers
    ssl_dhparam /etc/nginx/dhparam.pem;

    # Session caching
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
}
```

### Generate DH Parameters

```bash
# Generate 4096-bit DH parameters (takes several minutes)
openssl dhparam -out /etc/nginx/dhparam.pem 4096

# Or use pre-generated params from Mozilla (faster, still secure)
curl -sL https://ssl-config.mozilla.org/ffdhe2048.txt > /etc/nginx/dhparam.pem
```

### SSL Session Configuration

```nginx
# Shared session cache across all worker processes
# 10m = 10MB, enough for ~40,000 sessions
ssl_session_cache shared:SSL:10m;

# Session lifetime
ssl_session_timeout 1d;

# Disable session tickets (better forward secrecy)
# Enable only if you rotate ticket keys regularly
ssl_session_tickets off;
```

### TLS Version Comparison

| Version | Status | Performance | Security | Support |
|---------|--------|-------------|----------|---------|
| TLS 1.0 | Deprecated | Slow | Weak | Drop immediately |
| TLS 1.1 | Deprecated | Slow | Weak | Drop immediately |
| TLS 1.2 | Active | Good | Strong | All modern browsers |
| TLS 1.3 | Preferred | Best (0-RTT) | Strongest | 95%+ browsers |

---

## Let's Encrypt & Certbot

### Installation

```bash
# Debian/Ubuntu
sudo apt update
sudo apt install certbot python3-certbot-nginx

# RHEL/Fedora
sudo dnf install certbot python3-certbot-nginx

# Alpine
sudo apk add certbot certbot-nginx

# Snap (universal)
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot
```

### Obtaining Certificates

#### Nginx Plugin (Easiest)

Certbot automatically modifies your nginx config.

```bash
# Single domain
sudo certbot --nginx -d example.com

# Multiple domains
sudo certbot --nginx -d example.com -d www.example.com -d api.example.com

# Non-interactive (for automation)
sudo certbot --nginx --non-interactive --agree-tos \
    --email admin@example.com -d example.com
```

#### Webroot Method (No Restart)

Use when you don't want certbot to modify your nginx config.

```nginx
# Add this to your nginx server block first
location /.well-known/acme-challenge/ {
    root /var/www/certbot;
}
```

```bash
sudo certbot certonly --webroot -w /var/www/certbot -d example.com
```

#### Standalone Method

Certbot runs its own temporary web server (requires port 80 to be free).

```bash
# Stop nginx first
sudo systemctl stop nginx

sudo certbot certonly --standalone -d example.com

# Restart nginx
sudo systemctl start nginx
```

#### DNS Challenge (Wildcard Certificates)

Required for wildcard certificates (`*.example.com`).

```bash
# Manual DNS challenge
sudo certbot certonly --manual --preferred-challenges dns -d "*.example.com"

# With DNS plugin (Cloudflare example)
sudo certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d example.com -d "*.example.com"
```

Cloudflare credentials file:

```ini
# /etc/letsencrypt/cloudflare.ini
dns_cloudflare_api_token = your-api-token-here
```

```bash
# Secure the credentials file
sudo chmod 600 /etc/letsencrypt/cloudflare.ini
```

### Auto-Renewal

#### Systemd Timer (Recommended)

Certbot usually installs this automatically.

```ini
# /etc/systemd/system/certbot.timer
[Unit]
Description=Run certbot twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/certbot.service
[Unit]
Description=Certbot renewal

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet
```

```bash
# Enable and start
sudo systemctl enable certbot.timer
sudo systemctl start certbot.timer

# Check status
sudo systemctl list-timers certbot.timer
```

#### Cron Alternative

```bash
# /etc/cron.d/certbot
0 0,12 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
```

### Renewal Hooks

```bash
# Test renewal with hooks
sudo certbot renew --dry-run \
    --pre-hook "echo 'Before renewal'" \
    --post-hook "systemctl reload nginx" \
    --deploy-hook "echo 'Certificate renewed'"

# Hook scripts (placed in /etc/letsencrypt/renewal-hooks/)
# /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
#!/bin/bash
systemctl reload nginx
```

```bash
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

### Certificate File Locations

```
/etc/letsencrypt/live/example.com/
├── cert.pem          # Domain certificate only
├── chain.pem         # Intermediate CA certificate(s)
├── fullchain.pem     # cert.pem + chain.pem (use this for ssl_certificate)
├── privkey.pem       # Private key (use this for ssl_certificate_key)
└── README
```

---

## Certificate Management

### Certificate Chain Configuration

```nginx
# fullchain.pem includes: domain cert + intermediate CA cert(s)
ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

# Trusted certificate for OCSP stapling verification
ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
```

### Verify Certificate Chain

```bash
# Check certificate details
openssl x509 -in /etc/letsencrypt/live/example.com/fullchain.pem -text -noout

# Verify chain
openssl verify -CAfile /etc/letsencrypt/live/example.com/chain.pem \
    /etc/letsencrypt/live/example.com/cert.pem

# Check expiration
openssl x509 -in /etc/letsencrypt/live/example.com/fullchain.pem -noout -enddate

# Test SSL from outside
openssl s_client -connect example.com:443 -servername example.com
```

### Multiple Certificates (RSA + ECDSA)

Serve different certificate types for maximum compatibility and performance.

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    # RSA certificate (compatibility)
    ssl_certificate     /etc/nginx/certs/example.com-rsa.pem;
    ssl_certificate_key /etc/nginx/certs/example.com-rsa.key;

    # ECDSA certificate (performance) - Nginx picks the best one
    ssl_certificate     /etc/nginx/certs/example.com-ecdsa.pem;
    ssl_certificate_key /etc/nginx/certs/example.com-ecdsa.key;
}
```

---

## HSTS

HTTP Strict Transport Security tells browsers to always use HTTPS for this domain.

### Basic HSTS

```nginx
# 2-year max-age (recommended for production)
add_header Strict-Transport-Security "max-age=63072000" always;
```

### HSTS with Subdomains

```nginx
# Apply to all subdomains as well
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
```

### HSTS Preload

Submit to browser preload list (permanently enforced, difficult to undo).

```nginx
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
```

**Before enabling preload:**
1. Ensure ALL subdomains support HTTPS
2. Start with a short `max-age` (e.g., 300) and test
3. Submit at https://hstspreload.org/

### Gradual HSTS Rollout

```nginx
# Step 1: Short max-age, monitor for issues (1 week)
add_header Strict-Transport-Security "max-age=604800" always;

# Step 2: Increase to 1 month
add_header Strict-Transport-Security "max-age=2592000" always;

# Step 3: Include subdomains
add_header Strict-Transport-Security "max-age=2592000; includeSubDomains" always;

# Step 4: Full production (2 years + preload)
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
```

---

## OCSP Stapling

OCSP stapling embeds the certificate's revocation status in the TLS handshake, improving connection speed and privacy.

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    # Enable OCSP stapling
    ssl_stapling on;

    # Verify OCSP response using trusted CA cert
    ssl_stapling_verify on;

    # CA cert chain for verification (intermediate + root)
    ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;

    # DNS resolver for OCSP responder lookup
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;
}
```

### Verify OCSP Stapling

```bash
# Test OCSP stapling
openssl s_client -connect example.com:443 -servername example.com -status 2>/dev/null | \
    grep -A 17 "OCSP Response Status"

# Should show: "OCSP Response Status: successful (0x0)"
```

---

## Security Headers

### Complete Security Headers Configuration

```nginx
# /etc/nginx/includes/security-headers.conf

# Prevent MIME type sniffing
add_header X-Content-Type-Options nosniff always;

# Clickjacking protection
add_header X-Frame-Options DENY always;
# Or allow same-origin framing:
# add_header X-Frame-Options SAMEORIGIN always;

# XSS Protection (legacy browsers)
add_header X-XSS-Protection "1; mode=block" always;

# Referrer Policy
add_header Referrer-Policy strict-origin-when-cross-origin always;

# Permissions Policy (formerly Feature-Policy)
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;

# Content Security Policy
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self';" always;

# Cross-Origin policies
add_header Cross-Origin-Opener-Policy same-origin always;
add_header Cross-Origin-Resource-Policy same-origin always;
add_header Cross-Origin-Embedder-Policy require-corp always;
```

### Usage

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    include /etc/nginx/includes/security-headers.conf;

    # ... rest of config
}
```

### Header Reference

| Header | Value | Purpose |
|--------|-------|---------|
| `X-Content-Type-Options` | `nosniff` | Prevent MIME type sniffing |
| `X-Frame-Options` | `DENY` or `SAMEORIGIN` | Prevent clickjacking |
| `X-XSS-Protection` | `1; mode=block` | Legacy XSS filter |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | Control referrer leakage |
| `Permissions-Policy` | `camera=(), ...` | Disable browser features |
| `Content-Security-Policy` | `default-src 'self'; ...` | Control resource loading |
| `Strict-Transport-Security` | `max-age=63072000; ...` | Force HTTPS |
| `Cross-Origin-Opener-Policy` | `same-origin` | Isolate browsing context |
| `Cross-Origin-Resource-Policy` | `same-origin` | Prevent cross-origin reads |

### Content-Security-Policy Examples

```nginx
# Minimal CSP (strict)
add_header Content-Security-Policy "default-src 'self';" always;

# With Google Fonts and Analytics
add_header Content-Security-Policy "default-src 'self'; script-src 'self' https://www.googletagmanager.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: https://www.google-analytics.com;" always;

# API-only (no HTML rendering)
add_header Content-Security-Policy "default-src 'none'; frame-ancestors 'none';" always;

# Report-only mode (for testing)
add_header Content-Security-Policy-Report-Only "default-src 'self'; report-uri /csp-report;" always;
```

---

## Rate Limiting

### Basic Rate Limiting

```nginx
http {
    # Define rate limit zone
    # $binary_remote_addr = client IP (compact binary, 4 or 16 bytes)
    # zone=name:size     = shared memory zone name and size
    # rate=10r/s         = 10 requests per second
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;

    server {
        location / {
            # Apply rate limit
            # burst=20  = allow 20 excess requests to queue
            # nodelay   = process burst immediately (don't throttle)
            limit_req zone=general burst=20 nodelay;

            # Custom status code (default is 503)
            limit_req_status 429;

            proxy_pass http://backend;
        }
    }
}
```

### Multiple Rate Limit Zones

```nginx
http {
    # Global rate limit: 30 req/s per IP
    limit_req_zone $binary_remote_addr zone=global:10m rate=30r/s;

    # Login rate limit: 5 req/min per IP
    limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;

    # API rate limit: by API key
    limit_req_zone $http_x_api_key zone=api:10m rate=100r/s;

    server {
        # Global limit applies everywhere
        limit_req zone=global burst=50 nodelay;

        location /api/login {
            # Stricter limit for login endpoint
            limit_req zone=login burst=3 nodelay;
            proxy_pass http://backend;
        }

        location /api/ {
            # API key-based limiting
            limit_req zone=api burst=200 nodelay;
            proxy_pass http://backend;
        }
    }
}
```

### Connection Limiting

Limit the number of simultaneous connections per IP.

```nginx
http {
    # Define connection limit zone
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    server {
        # Max 20 simultaneous connections per IP
        limit_conn conn_limit 20;

        # Limit bandwidth per connection (useful for downloads)
        limit_rate 1m;               # 1MB/s per connection
        limit_rate_after 10m;        # Full speed for first 10MB

        location /downloads/ {
            # Tighter limits for download section
            limit_conn conn_limit 5;
            limit_rate 500k;
        }
    }
}
```

### Rate Limiting with Whitelisting

```nginx
http {
    # Map to identify whitelisted IPs
    geo $rate_limit {
        default         1;
        10.0.0.0/8      0;    # Internal network
        192.168.0.0/16  0;    # Private network
        203.0.113.50    0;    # Monitoring server
    }

    # Only apply rate limiting to non-whitelisted IPs
    map $rate_limit $rate_limit_key {
        0 "";
        1 $binary_remote_addr;
    }

    limit_req_zone $rate_limit_key zone=api:10m rate=10r/s;

    server {
        location /api/ {
            limit_req zone=api burst=20 nodelay;
            proxy_pass http://backend;
        }
    }
}
```

### Logging Rate-Limited Requests

```nginx
http {
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

    # Log rate-limited requests at warn level
    limit_req_log_level warn;

    # Custom log format for rate-limited requests
    log_format ratelimit '$remote_addr - $remote_user [$time_local] '
                         '"$request" $status $body_bytes_sent '
                         '"limit_req_status=$limit_req_status"';
}
```

---

## IP Restrictions

### Allow/Deny Directives

```nginx
location /admin/ {
    # Allow specific IPs and ranges
    allow 10.0.0.0/8;
    allow 192.168.1.0/24;
    allow 203.0.113.50;

    # Deny everything else
    deny all;

    proxy_pass http://admin_backend;
}
```

**Order matters:** Nginx evaluates `allow`/`deny` rules in order and uses the first match.

### Geo Module

Map client IP to a variable for conditional logic.

```nginx
http {
    geo $allowed_country {
        default         no;
        10.0.0.0/8      yes;    # Internal
        203.0.0.0/8     yes;    # Example allowed range
    }

    server {
        location / {
            if ($allowed_country = no) {
                return 403;
            }
            proxy_pass http://backend;
        }
    }
}
```

### GeoIP2 Module

For geo-blocking or geo-routing by country. Requires `ngx_http_geoip2_module` and MaxMind GeoLite2 database.

```nginx
# Load GeoIP2 module
load_module modules/ngx_http_geoip2_module.so;

http {
    geoip2 /usr/share/GeoIP/GeoLite2-Country.mmdb {
        auto_reload 60m;
        $geoip2_metadata_country_build metadata build_epoch;
        $geoip2_data_country_code country iso_code;
        $geoip2_data_country_name country names en;
    }

    # Block specific countries
    map $geoip2_data_country_code $blocked_country {
        default no;
        XX      yes;    # Replace XX with country code
        YY      yes;
    }

    server {
        if ($blocked_country = yes) {
            return 403;
        }
    }
}
```

### Combining IP and Authentication

```nginx
location /admin/ {
    # Require BOTH IP match AND authentication
    satisfy all;

    allow 10.0.0.0/8;
    deny all;

    auth_basic "Admin Area";
    auth_basic_user_file /etc/nginx/.htpasswd;

    proxy_pass http://admin_backend;
}

location /internal/ {
    # Require EITHER IP match OR authentication
    satisfy any;

    allow 10.0.0.0/8;
    deny all;

    auth_basic "Internal Area";
    auth_basic_user_file /etc/nginx/.htpasswd;

    proxy_pass http://internal_backend;
}
```

---

## Basic Authentication

### Setup

```bash
# Install htpasswd utility
sudo apt install apache2-utils    # Debian/Ubuntu
sudo dnf install httpd-tools      # RHEL/Fedora

# Create password file with first user
sudo htpasswd -c /etc/nginx/.htpasswd admin

# Add additional users (no -c flag!)
sudo htpasswd /etc/nginx/.htpasswd user2

# Use bcrypt hashing (more secure, requires htpasswd 2.4+)
sudo htpasswd -B /etc/nginx/.htpasswd user3

# Secure the file
sudo chown root:www-data /etc/nginx/.htpasswd
sudo chmod 640 /etc/nginx/.htpasswd
```

### Nginx Configuration

```nginx
location /admin/ {
    auth_basic "Admin Area";
    auth_basic_user_file /etc/nginx/.htpasswd;

    proxy_pass http://admin_backend;
}

# Disable auth for specific sub-paths
location /admin/health {
    auth_basic off;
    proxy_pass http://admin_backend;
}
```

### Auth for Entire Site with Exceptions

```nginx
server {
    listen 443 ssl http2;
    server_name staging.example.com;

    # Global auth for staging environment
    auth_basic "Staging Environment";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://backend;
    }

    # Exempt health checks and webhooks
    location /health {
        auth_basic off;
        proxy_pass http://backend;
    }

    location /webhooks/ {
        auth_basic off;
        proxy_pass http://backend;
    }
}
```

---

## Mutual TLS (mTLS)

Mutual TLS requires both server and client to present certificates, providing strong authentication.

### Server Configuration

```nginx
server {
    listen 443 ssl http2;
    server_name api.example.com;

    # Server certificate (standard)
    ssl_certificate     /etc/nginx/certs/server.pem;
    ssl_certificate_key /etc/nginx/certs/server.key;

    # CA certificate that signed client certificates
    ssl_client_certificate /etc/nginx/certs/client-ca.pem;

    # Require client certificate
    ssl_verify_client on;
    # Or make it optional:
    # ssl_verify_client optional;

    # Verification depth (how many intermediate CAs to check)
    ssl_verify_depth 2;

    # CRL for revoked client certificates
    ssl_crl /etc/nginx/certs/client-revoked.crl;

    location / {
        # Pass client certificate info to backend
        proxy_set_header X-SSL-Client-DN $ssl_client_s_dn;
        proxy_set_header X-SSL-Client-Serial $ssl_client_serial;
        proxy_set_header X-SSL-Client-Verify $ssl_client_verify;
        proxy_set_header X-SSL-Client-Fingerprint $ssl_client_fingerprint;

        proxy_pass http://backend;
    }
}
```

### Optional Client Certificate

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_client_certificate /etc/nginx/certs/client-ca.pem;
    ssl_verify_client optional;

    location /public/ {
        # No client cert required
        proxy_pass http://backend;
    }

    location /secure/ {
        # Require valid client cert for this path
        if ($ssl_client_verify != SUCCESS) {
            return 403;
        }
        proxy_pass http://secure_backend;
    }
}
```

### Generate Client Certificates

```bash
# 1. Create CA (one-time)
openssl genrsa -out client-ca.key 4096
openssl req -new -x509 -days 3650 -key client-ca.key -out client-ca.pem \
    -subj "/CN=Client CA"

# 2. Generate client key and CSR
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr \
    -subj "/CN=client-name/O=organization"

# 3. Sign with CA
openssl x509 -req -days 365 -in client.csr -CA client-ca.pem \
    -CAkey client-ca.key -CAcreateserial -out client.pem

# 4. Create PKCS12 bundle for browser import
openssl pkcs12 -export -out client.p12 \
    -inkey client.key -in client.pem -certfile client-ca.pem

# 5. Test with curl
curl --cert client.pem --key client.key https://api.example.com/
```

### Client Certificate Variables

| Variable | Description |
|----------|-------------|
| `$ssl_client_verify` | `SUCCESS`, `FAILED:reason`, or `NONE` |
| `$ssl_client_s_dn` | Subject DN of client certificate |
| `$ssl_client_i_dn` | Issuer DN of client certificate |
| `$ssl_client_serial` | Serial number of client certificate |
| `$ssl_client_fingerprint` | SHA1 fingerprint of client certificate |
| `$ssl_client_cert` | PEM-encoded client certificate |
| `$ssl_client_raw_cert` | PEM-encoded client certificate (unescaped) |
| `$ssl_client_escaped_cert` | URL-encoded client certificate |

---

## HTTP to HTTPS Redirect

### Standard Redirect

```nginx
# Redirect all HTTP to HTTPS
server {
    listen 80;
    server_name example.com www.example.com;
    return 301 https://example.com$request_uri;
}
```

### Catch-All Redirect

```nginx
# Redirect ANY domain on HTTP to HTTPS
server {
    listen 80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}
```

### Redirect with Let's Encrypt Exception

```nginx
server {
    listen 80;
    server_name example.com www.example.com;

    # Allow ACME challenge for certificate renewal
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect everything else to HTTPS
    location / {
        return 301 https://example.com$request_uri;
    }
}
```

### WWW to Non-WWW (with HTTPS)

```nginx
# Redirect www to non-www
server {
    listen 443 ssl http2;
    server_name www.example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    return 301 https://example.com$request_uri;
}

# Redirect HTTP www to HTTPS non-www
server {
    listen 80;
    server_name www.example.com;
    return 301 https://example.com$request_uri;
}
```

### Redirect with Preserved POST Body

Note: `301` and `302` redirects convert POST to GET. Use `307`/`308` to preserve the method.

```nginx
# 308 Permanent Redirect (preserves HTTP method)
server {
    listen 80;
    server_name api.example.com;
    return 308 https://api.example.com$request_uri;
}
```

| Status | Permanent | Preserves Method |
|--------|-----------|-----------------|
| 301 | Yes | No (POST → GET) |
| 302 | No | No (POST → GET) |
| 307 | No | Yes |
| 308 | Yes | Yes |
