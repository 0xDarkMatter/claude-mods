# Authorization Patterns

Comprehensive reference for authorization models: RBAC, ABAC, ReBAC, row-level security, multi-tenant, and audit logging.

## RBAC (Role-Based Access Control)

The most common authorization model. Users are assigned roles, and roles have permissions.

### Data Model

```sql
-- Core RBAC tables
CREATE TABLE roles (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT UNIQUE NOT NULL,      -- 'admin', 'editor', 'viewer'
    description TEXT,
    created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE permissions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource    TEXT NOT NULL,              -- 'posts', 'users', 'settings'
    action      TEXT NOT NULL,              -- 'create', 'read', 'update', 'delete'
    UNIQUE(resource, action)
);

CREATE TABLE role_permissions (
    role_id       UUID REFERENCES roles(id) ON DELETE CASCADE,
    permission_id UUID REFERENCES permissions(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE user_roles (
    user_id    UUID REFERENCES users(id) ON DELETE CASCADE,
    role_id    UUID REFERENCES roles(id) ON DELETE CASCADE,
    granted_by UUID REFERENCES users(id),
    granted_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (user_id, role_id)
);
```

### Role Hierarchy

```
super_admin
  └─ admin
       ├─ editor
       │    └─ viewer
       └─ moderator
            └─ viewer
```

```sql
-- Role hierarchy table
CREATE TABLE role_hierarchy (
    parent_role_id UUID REFERENCES roles(id),
    child_role_id  UUID REFERENCES roles(id),
    PRIMARY KEY (parent_role_id, child_role_id)
);

-- Query: Get all permissions for a user (including inherited)
WITH RECURSIVE effective_roles AS (
    -- Direct roles
    SELECT role_id FROM user_roles WHERE user_id = $1
    UNION
    -- Inherited roles (parent inherits child permissions)
    SELECT rh.child_role_id
    FROM role_hierarchy rh
    JOIN effective_roles er ON er.role_id = rh.parent_role_id
)
SELECT DISTINCT p.resource, p.action
FROM effective_roles er
JOIN role_permissions rp ON rp.role_id = er.role_id
JOIN permissions p ON p.id = rp.permission_id;
```

### Middleware Patterns

#### Node.js / Express

```javascript
// Permission checking middleware
function requirePermission(resource, action) {
  return async (req, res, next) => {
    const userId = req.auth.sub;

    const hasPermission = await db.query(`
      WITH RECURSIVE effective_roles AS (
        SELECT role_id FROM user_roles WHERE user_id = $1
        UNION
        SELECT rh.child_role_id
        FROM role_hierarchy rh
        JOIN effective_roles er ON er.role_id = rh.parent_role_id
      )
      SELECT EXISTS (
        SELECT 1
        FROM effective_roles er
        JOIN role_permissions rp ON rp.role_id = er.role_id
        JOIN permissions p ON p.id = rp.permission_id
        WHERE p.resource = $2 AND p.action = $3
      )
    `, [userId, resource, action]);

    if (!hasPermission.rows[0].exists) {
      return res.status(403).json({
        error: 'Forbidden',
        required: `${action}:${resource}`,
      });
    }

    next();
  };
}

// Usage
app.get('/api/posts', requirePermission('posts', 'read'), listPosts);
app.post('/api/posts', requirePermission('posts', 'create'), createPost);
app.delete('/api/posts/:id', requirePermission('posts', 'delete'), deletePost);
```

#### Python / FastAPI

```python
from fastapi import Depends, HTTPException, status
from functools import wraps

def require_permission(resource: str, action: str):
    async def checker(user: User = Depends(get_current_user)):
        has_perm = await db.fetch_val("""
            SELECT EXISTS (
                SELECT 1 FROM user_roles ur
                JOIN role_permissions rp ON rp.role_id = ur.role_id
                JOIN permissions p ON p.id = rp.permission_id
                WHERE ur.user_id = $1 AND p.resource = $2 AND p.action = $3
            )
        """, user.id, resource, action)

        if not has_perm:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Missing permission: {action}:{resource}",
            )
        return user
    return Depends(checker)

# Usage
@app.get("/api/posts")
async def list_posts(user: User = require_permission("posts", "read")):
    return await get_posts()

@app.post("/api/posts")
async def create_post(
    post: PostCreate,
    user: User = require_permission("posts", "create"),
):
    return await insert_post(post, user.id)
```

#### Go

```go
// Middleware pattern
func RequirePermission(resource, action string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            userID := r.Context().Value("userID").(string)

            allowed, err := checkPermission(r.Context(), userID, resource, action)
            if err != nil {
                http.Error(w, "Internal error", http.StatusInternalServerError)
                return
            }
            if !allowed {
                http.Error(w, "Forbidden", http.StatusForbidden)
                return
            }

            next.ServeHTTP(w, r)
        })
    }
}

// Usage with chi router
r.Route("/api/posts", func(r chi.Router) {
    r.With(RequirePermission("posts", "read")).Get("/", listPosts)
    r.With(RequirePermission("posts", "create")).Post("/", createPost)
    r.With(RequirePermission("posts", "delete")).Delete("/{id}", deletePost)
})
```

### When RBAC Breaks Down

| Signal | Problem | Solution |
|--------|---------|----------|
| 50+ roles | Role explosion | Consider ABAC |
| Roles like "alice-docs-editor" | Per-user roles | Consider ReBAC |
| Roles vary by context | Context-dependent access | Consider ABAC |
| "Owner can edit own resources" | Relationship-based | Consider ReBAC |

## ABAC (Attribute-Based Access Control)

Decisions based on attributes of the subject, resource, action, and environment.

### Policy Structure

```
PERMIT if:
  subject.role == "doctor"
  AND resource.type == "medical_record"
  AND resource.department == subject.department
  AND environment.time BETWEEN 08:00 AND 18:00
  AND action == "read"
```

### Implementation

```javascript
// Policy engine
class PolicyEngine {
  constructor(policies) {
    this.policies = policies;
  }

  evaluate(subject, resource, action, environment) {
    for (const policy of this.policies) {
      const result = policy.evaluate(subject, resource, action, environment);
      if (result === 'PERMIT') return true;
      if (result === 'DENY') return false;
      // 'NOT_APPLICABLE' continues to next policy
    }
    return false; // Default deny
  }
}

// Define policies
const policies = [
  {
    name: 'owner-full-access',
    evaluate: (subject, resource, action, env) => {
      if (resource.ownerId === subject.id) return 'PERMIT';
      return 'NOT_APPLICABLE';
    },
  },
  {
    name: 'department-read',
    evaluate: (subject, resource, action, env) => {
      if (
        action === 'read' &&
        subject.department === resource.department
      ) {
        return 'PERMIT';
      }
      return 'NOT_APPLICABLE';
    },
  },
  {
    name: 'business-hours-only',
    evaluate: (subject, resource, action, env) => {
      const hour = env.currentTime.getHours();
      if (resource.classification === 'restricted' && (hour < 8 || hour > 18)) {
        return 'DENY';
      }
      return 'NOT_APPLICABLE';
    },
  },
];

// Usage
const engine = new PolicyEngine(policies);
const allowed = engine.evaluate(
  { id: 'user_123', role: 'doctor', department: 'cardiology' },
  { type: 'record', ownerId: 'user_456', department: 'cardiology', classification: 'normal' },
  'read',
  { currentTime: new Date() }
);
```

### Combining Algorithms

| Algorithm | Behavior |
|-----------|----------|
| **Deny-overrides** | Any DENY wins (most restrictive) |
| **Permit-overrides** | Any PERMIT wins (most permissive) |
| **First-applicable** | First matching policy decides |
| **Only-one-applicable** | Error if multiple policies match |

**Recommendation:** Use deny-overrides for security-critical systems, first-applicable for performance.

## ReBAC (Relationship-Based Access Control)

Based on Google's Zanzibar paper. Access is determined by relationships between users and resources.

### Core Concepts

**Relationship tuple:** `user:alice#viewer@document:report`
- Subject: `user:alice`
- Relation: `viewer`
- Object: `document:report`

Reading: "Alice is a viewer of document:report"

### Authorization Model (OpenFGA/SpiceDB)

```yaml
# OpenFGA model
model:
  schema 1.1

type user

type organization
  relations
    define member: [user]
    define admin: [user]

type folder
  relations
    define org: [organization]
    define owner: [user]
    define editor: [user, organization#member] or owner
    define viewer: [user, organization#member] or editor

type document
  relations
    define parent: [folder]
    define owner: [user]
    define editor: [user] or owner or editor from parent
    define viewer: [user] or editor or viewer from parent
```

### Relationship Tuples

```
# Alice owns the Engineering folder
user:alice#owner@folder:engineering

# Engineering folder belongs to Acme org
organization:acme#org@folder:engineering

# Bob is a member of Acme
user:bob#member@organization:acme

# Report document is in Engineering folder
folder:engineering#parent@document:report

# Now: Can Bob view document:report?
# Bob is member of Acme → Acme is org of Engineering folder
# → folder viewers include org members → document viewers include folder viewers
# → YES, Bob can view document:report
```

### OpenFGA Integration

```javascript
// OpenFGA SDK
import { OpenFgaClient } from '@openfga/sdk';

const fga = new OpenFgaClient({
  apiUrl: process.env.OPENFGA_API_URL,
  storeId: process.env.OPENFGA_STORE_ID,
});

// Write a relationship
await fga.write({
  writes: [
    {
      user: 'user:alice',
      relation: 'editor',
      object: 'document:report',
    },
  ],
});

// Check access
const { allowed } = await fga.check({
  user: 'user:bob',
  relation: 'viewer',
  object: 'document:report',
});

if (!allowed) {
  return res.status(403).json({ error: 'Access denied' });
}

// List objects a user can access
const { objects } = await fga.listObjects({
  user: 'user:alice',
  relation: 'viewer',
  type: 'document',
});
// objects: ['document:report', 'document:spec', ...]

// List users with access to an object
const { users } = await fga.listUsers({
  object: { type: 'document', id: 'report' },
  relation: 'viewer',
  user_filters: [{ type: 'user' }],
});
```

### SpiceDB Integration

```go
// SpiceDB with authzed-go
import (
    v1 "github.com/authzed/authzed-go/proto/authzed/api/v1"
    "github.com/authzed/authzed-go/v1"
)

client, err := authzed.NewClient(
    "localhost:50051",
    grpc.WithInsecure(),
    grpcutil.WithInsecureBearerToken("my-token"),
)

// Write relationship
_, err = client.WriteRelationships(ctx, &v1.WriteRelationshipsRequest{
    Updates: []*v1.RelationshipUpdate{
        {
            Operation: v1.RelationshipUpdate_OPERATION_CREATE,
            Relationship: &v1.Relationship{
                Resource: &v1.ObjectReference{
                    ObjectType: "document",
                    ObjectId:   "report",
                },
                Relation: "viewer",
                Subject: &v1.SubjectReference{
                    Object: &v1.ObjectReference{
                        ObjectType: "user",
                        ObjectId:   "alice",
                    },
                },
            },
        },
    },
})

// Check permission
resp, err := client.CheckPermission(ctx, &v1.CheckPermissionRequest{
    Resource: &v1.ObjectReference{
        ObjectType: "document",
        ObjectId:   "report",
    },
    Permission: "view",
    Subject: &v1.SubjectReference{
        Object: &v1.ObjectReference{
            ObjectType: "user",
            ObjectId:   "bob",
        },
    },
})

if resp.Permissionship == v1.CheckPermissionResponse_PERMISSIONSHIP_HAS_PERMISSION {
    // Access granted
}
```

### When to Use ReBAC

| Scenario | RBAC | ReBAC |
|----------|------|-------|
| "Admins can manage users" | Good fit | Overkill |
| "Owner can edit their documents" | Awkward | Good fit |
| "Folder viewers can view contained documents" | Cannot model | Good fit |
| "Shared-with users can view" | Cannot model | Good fit |
| "Org members can access org resources" | Possible but fragile | Good fit |

## Row-Level Security (RLS)

Database-level authorization that filters query results based on the current user.

### PostgreSQL RLS

```sql
-- Enable RLS on table
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

-- Force RLS for table owner too (optional, for safety)
ALTER TABLE documents FORCE ROW LEVEL SECURITY;

-- Policy: Users can only see their own documents
CREATE POLICY "users_own_documents" ON documents
    FOR ALL
    USING (owner_id = current_setting('app.current_user_id')::uuid);

-- Policy: Users can see documents shared with them
CREATE POLICY "shared_documents" ON documents
    FOR SELECT
    USING (
        id IN (
            SELECT document_id FROM document_shares
            WHERE user_id = current_setting('app.current_user_id')::uuid
        )
    );

-- Policy: Admins can see all documents
CREATE POLICY "admin_full_access" ON documents
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM user_roles
            WHERE user_id = current_setting('app.current_user_id')::uuid
            AND role = 'admin'
        )
    );

-- Set the current user context before queries
SET app.current_user_id = 'user_abc123';
SELECT * FROM documents; -- Only returns allowed rows
```

### Supabase RLS

```sql
-- Supabase provides auth.uid() and auth.jwt() functions

-- Users can read their own profile
CREATE POLICY "read_own_profile" ON profiles
    FOR SELECT USING (auth.uid() = id);

-- Users can update their own profile
CREATE POLICY "update_own_profile" ON profiles
    FOR UPDATE USING (auth.uid() = id);

-- Users can read posts in their organization
CREATE POLICY "org_posts" ON posts
    FOR SELECT USING (
        org_id IN (
            SELECT org_id FROM org_members
            WHERE user_id = auth.uid()
        )
    );

-- Service role bypasses RLS (for admin operations)
-- Use supabase.createClient(url, SERVICE_ROLE_KEY) for admin access
```

### Application-Level Row Filtering

When you can't use RLS (e.g., non-PostgreSQL databases):

```javascript
// Query builder pattern
class AuthorizedQuery {
  constructor(user) {
    this.user = user;
    this.filters = [];
  }

  forResource(table) {
    if (this.user.role === 'admin') {
      // No filter for admins
    } else if (this.user.role === 'manager') {
      this.filters.push(`${table}.org_id = ?`, this.user.orgId);
    } else {
      this.filters.push(`${table}.owner_id = ?`, this.user.id);
    }
    return this;
  }

  apply(queryBuilder) {
    for (const filter of this.filters) {
      queryBuilder.where(filter);
    }
    return queryBuilder;
  }
}

// Usage
const query = new AuthorizedQuery(currentUser)
  .forResource('documents')
  .apply(db('documents').select('*'));
```

## Multi-Tenant Authorization

### Tenant Isolation Strategies

| Strategy | Isolation | Complexity | Use When |
|----------|-----------|------------|----------|
| **Shared database, shared schema** | Row-level (tenant_id column) | Low | SaaS with many small tenants |
| **Shared database, separate schemas** | Schema-level | Medium | Moderate data isolation needs |
| **Separate databases** | Complete | High | Strict compliance, large tenants |

### Shared Schema with tenant_id

```sql
-- Every table has a tenant_id
CREATE TABLE documents (
    id        UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    title     TEXT NOT NULL,
    content   TEXT,
    owner_id  UUID NOT NULL REFERENCES users(id),
    CONSTRAINT fk_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

-- RLS policy enforces tenant isolation
CREATE POLICY "tenant_isolation" ON documents
    FOR ALL
    USING (tenant_id = current_setting('app.current_tenant_id')::uuid);

-- Index for performance
CREATE INDEX idx_documents_tenant ON documents(tenant_id);
```

### Tenant-Scoped Roles

```sql
-- Roles are scoped to a tenant
CREATE TABLE tenant_user_roles (
    tenant_id UUID REFERENCES tenants(id),
    user_id   UUID REFERENCES users(id),
    role      TEXT NOT NULL, -- 'owner', 'admin', 'member', 'viewer'
    PRIMARY KEY (tenant_id, user_id)
);

-- A user can be admin in one tenant and viewer in another
INSERT INTO tenant_user_roles VALUES
    ('tenant_1', 'alice', 'admin'),
    ('tenant_2', 'alice', 'viewer');
```

### Middleware: Tenant Context

```javascript
// Express middleware - set tenant context
async function tenantContext(req, res, next) {
  // Determine tenant from subdomain, header, or JWT claim
  const tenantId =
    req.headers['x-tenant-id'] ||
    req.auth?.tenantId ||
    extractFromSubdomain(req.hostname);

  if (!tenantId) {
    return res.status(400).json({ error: 'Tenant not specified' });
  }

  // Verify user belongs to tenant
  const membership = await db.query(
    'SELECT role FROM tenant_user_roles WHERE tenant_id = $1 AND user_id = $2',
    [tenantId, req.auth.sub]
  );

  if (!membership.rows.length) {
    return res.status(403).json({ error: 'Not a member of this tenant' });
  }

  req.tenant = { id: tenantId, role: membership.rows[0].role };

  // Set PostgreSQL session variable for RLS
  await db.query("SET app.current_tenant_id = $1", [tenantId]);

  next();
}
```

### Cross-Tenant Access

```javascript
// Controlled cross-tenant access (e.g., shared documents)
async function checkCrossTenantAccess(userId, resourceId, targetTenantId) {
  // Check if resource has cross-tenant sharing enabled
  const share = await db.query(`
    SELECT permission FROM cross_tenant_shares
    WHERE resource_id = $1
    AND shared_with_tenant_id = $2
    AND (expires_at IS NULL OR expires_at > now())
  `, [resourceId, targetTenantId]);

  if (!share.rows.length) return false;
  return share.rows[0].permission; // 'read', 'write', etc.
}
```

## API Authorization

### Scope-Based (OAuth2 Scopes)

```javascript
// Middleware that checks OAuth2 scopes
function requireScopes(...scopes) {
  return (req, res, next) => {
    const tokenScopes = req.auth.scope?.split(' ') || [];
    const missing = scopes.filter((s) => !tokenScopes.includes(s));
    if (missing.length) {
      return res.status(403).json({
        error: 'insufficient_scope',
        missing,
      });
    }
    next();
  };
}
```

### Claims-Based (JWT Claims)

```javascript
// Check JWT claims for authorization
function requireClaim(claim, value) {
  return (req, res, next) => {
    if (req.auth[claim] !== value) {
      return res.status(403).json({ error: `Required claim: ${claim}=${value}` });
    }
    next();
  };
}

// Usage
app.get('/admin', requireClaim('role', 'admin'), adminDashboard);
app.get('/org/:orgId', (req, res, next) => {
  if (req.auth.org_id !== req.params.orgId) {
    return res.status(403).json({ error: 'Wrong organization' });
  }
  next();
}, orgDashboard);
```

### API Key Permissions

```javascript
// API key with scoped permissions
async function apiKeyAuth(req, res, next) {
  const apiKey = req.headers['x-api-key'];
  if (!apiKey) return res.status(401).json({ error: 'API key required' });

  // Look up by prefix, verify by hash
  const prefix = apiKey.substring(0, 8);
  const keyRecord = await db.query(
    'SELECT * FROM api_keys WHERE prefix = $1 AND revoked = false',
    [prefix]
  );

  if (!keyRecord.rows.length) {
    return res.status(401).json({ error: 'Invalid API key' });
  }

  const record = keyRecord.rows[0];
  const keyHash = crypto.createHash('sha256').update(apiKey).digest('hex');

  if (!crypto.timingSafeEqual(
    Buffer.from(keyHash),
    Buffer.from(record.key_hash)
  )) {
    return res.status(401).json({ error: 'Invalid API key' });
  }

  // Check expiry
  if (record.expires_at && record.expires_at < new Date()) {
    return res.status(401).json({ error: 'API key expired' });
  }

  req.apiKey = {
    id: record.id,
    permissions: record.permissions, // ['read:data', 'write:data']
    rateLimitTier: record.rate_limit_tier,
  };

  next();
}
```

## Feature Flags as Authorization

Feature flags can serve as a lightweight authorization mechanism for feature rollouts.

```javascript
// Simple feature flag implementation
class FeatureFlags {
  constructor(config) {
    this.flags = config;
  }

  isEnabled(flag, context = {}) {
    const config = this.flags[flag];
    if (!config) return false;

    // Global enable/disable
    if (typeof config === 'boolean') return config;

    // Percentage rollout
    if (config.percentage !== undefined) {
      const hash = this.hashUser(context.userId);
      return hash % 100 < config.percentage;
    }

    // User allowlist
    if (config.allowedUsers?.includes(context.userId)) return true;

    // Role-based
    if (config.allowedRoles?.includes(context.role)) return true;

    // Tenant-based
    if (config.allowedTenants?.includes(context.tenantId)) return true;

    return config.defaultValue ?? false;
  }

  hashUser(userId) {
    return parseInt(
      crypto.createHash('md5').update(userId).digest('hex').slice(0, 8),
      16
    ) % 100;
  }
}

// Usage
const flags = new FeatureFlags({
  new_editor: { percentage: 25 },
  beta_api: { allowedRoles: ['admin'], allowedTenants: ['acme'] },
  dark_mode: true,
});

if (flags.isEnabled('new_editor', { userId: user.id })) {
  // Show new editor
}
```

## Audit Logging

### What to Log

| Category | Events |
|----------|--------|
| **Authentication** | Login success/failure, logout, password change, MFA enable/disable |
| **Authorization** | Permission denied, role changes, policy evaluations |
| **Data access** | Read sensitive data, export data, search queries |
| **Data modification** | Create, update, delete operations |
| **Admin actions** | User management, configuration changes, key rotation |
| **Security** | Suspicious activity, rate limit hits, blocked requests |

### Audit Log Schema

```sql
CREATE TABLE audit_logs (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    timestamp   TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_id    UUID,                          -- Who did it
    actor_type  TEXT NOT NULL,                 -- 'user', 'service', 'system'
    action      TEXT NOT NULL,                 -- 'user.login', 'document.delete'
    resource    TEXT,                          -- 'document:123', 'user:456'
    outcome     TEXT NOT NULL,                 -- 'success', 'failure', 'denied'
    metadata    JSONB DEFAULT '{}',            -- Additional context
    ip_address  INET,
    user_agent  TEXT,
    tenant_id   UUID,
    request_id  UUID                           -- Correlation ID
);

-- Index for common queries
CREATE INDEX idx_audit_actor ON audit_logs(actor_id, timestamp DESC);
CREATE INDEX idx_audit_action ON audit_logs(action, timestamp DESC);
CREATE INDEX idx_audit_resource ON audit_logs(resource, timestamp DESC);
CREATE INDEX idx_audit_tenant ON audit_logs(tenant_id, timestamp DESC);

-- Prevent modification (append-only)
REVOKE UPDATE, DELETE ON audit_logs FROM app_user;
```

### Audit Logging Implementation

```javascript
// Audit logger
class AuditLogger {
  constructor(db) {
    this.db = db;
  }

  async log(event) {
    await this.db.query(`
      INSERT INTO audit_logs
        (actor_id, actor_type, action, resource, outcome, metadata, ip_address, user_agent, tenant_id, request_id)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
    `, [
      event.actorId,
      event.actorType || 'user',
      event.action,
      event.resource,
      event.outcome || 'success',
      JSON.stringify(event.metadata || {}),
      event.ipAddress,
      event.userAgent,
      event.tenantId,
      event.requestId,
    ]);
  }
}

// Express middleware for automatic audit logging
function auditMiddleware(action, resourceFn) {
  return (req, res, next) => {
    const originalJson = res.json.bind(res);

    res.json = (body) => {
      const resource = resourceFn ? resourceFn(req, body) : undefined;
      const outcome = res.statusCode < 400 ? 'success' : 'failure';

      // Fire and forget (don't block response)
      auditLogger.log({
        actorId: req.auth?.sub,
        actorType: 'user',
        action,
        resource,
        outcome,
        metadata: {
          method: req.method,
          path: req.path,
          statusCode: res.statusCode,
        },
        ipAddress: req.ip,
        userAgent: req.headers['user-agent'],
        tenantId: req.tenant?.id,
        requestId: req.headers['x-request-id'],
      }).catch(console.error);

      return originalJson(body);
    };

    next();
  };
}

// Usage
app.delete('/api/documents/:id',
  auditMiddleware('document.delete', (req) => `document:${req.params.id}`),
  requirePermission('documents', 'delete'),
  deleteDocument
);
```

### Compliance Considerations

| Requirement | Implementation |
|-------------|----------------|
| **Immutability** | Append-only table, no UPDATE/DELETE permissions |
| **Retention** | Partition by month, archive to cold storage after N months |
| **Integrity** | Hash chain (each entry includes hash of previous) |
| **Access** | Separate read permissions for audit logs |
| **Availability** | Async writes with retry queue, separate storage |
| **Search** | Index on actor, action, resource, timestamp |

## Testing Authorization

### Unit Testing Policies

```javascript
// Test RBAC permissions
describe('Authorization', () => {
  it('admin can delete posts', async () => {
    const allowed = await checkPermission('admin', 'posts', 'delete');
    expect(allowed).toBe(true);
  });

  it('viewer cannot delete posts', async () => {
    const allowed = await checkPermission('viewer', 'posts', 'delete');
    expect(allowed).toBe(false);
  });

  it('editor can update posts', async () => {
    const allowed = await checkPermission('editor', 'posts', 'update');
    expect(allowed).toBe(true);
  });
});
```

### Permission Matrix Testing

```javascript
// Test every role × resource × action combination
const matrix = {
  admin:   { posts: ['create', 'read', 'update', 'delete'], users: ['create', 'read', 'update', 'delete'] },
  editor:  { posts: ['create', 'read', 'update'],           users: ['read'] },
  viewer:  { posts: ['read'],                                users: ['read'] },
};

for (const [role, permissions] of Object.entries(matrix)) {
  for (const [resource, actions] of Object.entries(permissions)) {
    for (const action of ['create', 'read', 'update', 'delete']) {
      const expected = actions.includes(action);
      it(`${role} ${expected ? 'can' : 'cannot'} ${action} ${resource}`, async () => {
        const result = await checkPermission(role, resource, action);
        expect(result).toBe(expected);
      });
    }
  }
}
```

### Integration Testing

```javascript
// Test authorization at the HTTP level
describe('POST /api/posts', () => {
  it('returns 403 for viewer', async () => {
    const res = await request(app)
      .post('/api/posts')
      .set('Authorization', `Bearer ${viewerToken}`)
      .send({ title: 'Test' });
    expect(res.status).toBe(403);
  });

  it('returns 201 for editor', async () => {
    const res = await request(app)
      .post('/api/posts')
      .set('Authorization', `Bearer ${editorToken}`)
      .send({ title: 'Test' });
    expect(res.status).toBe(201);
  });

  it('prevents cross-tenant access', async () => {
    const res = await request(app)
      .get('/api/posts/123') // belongs to tenant_1
      .set('Authorization', `Bearer ${tenant2UserToken}`);
    expect(res.status).toBe(404); // 404 not 403 to avoid info leakage
  });
});
```
