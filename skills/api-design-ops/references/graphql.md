# GraphQL Patterns

## Table of Contents

- [Schema Design](#schema-design)
- [Resolver Patterns](#resolver-patterns)
- [Authentication and Authorization](#authentication-and-authorization)
- [Error Handling](#error-handling)
- [Pagination](#pagination)
- [Fragments, Interfaces, Unions](#fragments-interfaces-unions)
- [Schema Stitching and Federation](#schema-stitching-and-federation)
- [Code-First vs Schema-First](#code-first-vs-schema-first)
- [Performance](#performance)
- [TypeScript and GraphQL](#typescript-and-graphql)
- [When GraphQL Is Overkill](#when-graphql-is-overkill)

---

## Schema Design

### Types, Queries, and Mutations

```graphql
# Scalar types: String, Int, Float, Boolean, ID
# Custom scalars for domain types
scalar DateTime
scalar Email
scalar URL

type User {
  id: ID!
  name: String!
  email: Email!
  avatar: URL
  role: UserRole!
  posts(first: Int = 10, after: String): PostConnection!
  createdAt: DateTime!
}

enum UserRole {
  ADMIN
  MEMBER
  VIEWER
}

# Queries - read operations
type Query {
  user(id: ID!): User
  users(
    first: Int = 20
    after: String
    filter: UserFilter
    orderBy: UserOrderBy = CREATED_AT_DESC
  ): UserConnection!
  me: User!              # Current authenticated user
}

# Mutations - write operations
type Mutation {
  createUser(input: CreateUserInput!): CreateUserPayload!
  updateUser(input: UpdateUserInput!): UpdateUserPayload!
  deleteUser(id: ID!): DeleteUserPayload!
}

# Input types (separate from output types)
input CreateUserInput {
  name: String!
  email: Email!
  role: UserRole = MEMBER
}

input UpdateUserInput {
  id: ID!
  name: String
  email: Email
  role: UserRole
}

input UserFilter {
  role: UserRole
  search: String
  createdAfter: DateTime
}

enum UserOrderBy {
  CREATED_AT_ASC
  CREATED_AT_DESC
  NAME_ASC
  NAME_DESC
}
```

### Mutation Payloads

Always return a payload type (not the entity directly):

```graphql
type CreateUserPayload {
  user: User!
  clientMutationId: String   # Relay convention
}

type UpdateUserPayload {
  user: User!
}

type DeleteUserPayload {
  deletedId: ID!
  success: Boolean!
}

# For operations that can partially fail
type BulkDeleteUsersPayload {
  deletedIds: [ID!]!
  errors: [BulkError!]!
}

type BulkError {
  id: ID!
  message: String!
  code: ErrorCode!
}
```

### Subscriptions

```graphql
type Subscription {
  # Simple subscription
  orderStatusChanged(orderId: ID!): Order!

  # Filtered subscription
  newMessage(channelId: ID!): Message!

  # With initial state
  userPresence(teamId: ID!): PresenceEvent!
}

enum PresenceEventType {
  ONLINE
  OFFLINE
  AWAY
}

type PresenceEvent {
  user: User!
  type: PresenceEventType!
  timestamp: DateTime!
}
```

## Resolver Patterns

### Basic Resolver Structure (TypeScript)

```typescript
const resolvers: Resolvers = {
  Query: {
    user: async (_, { id }, context) => {
      return context.dataSources.users.findById(id);
    },
    users: async (_, { first, after, filter }, context) => {
      return context.dataSources.users.findMany({ first, after, filter });
    },
    me: async (_, __, context) => {
      if (!context.currentUser) {
        throw new AuthenticationError("Not authenticated");
      }
      return context.currentUser;
    },
  },

  Mutation: {
    createUser: async (_, { input }, context) => {
      const user = await context.dataSources.users.create(input);
      return { user };
    },
  },

  // Field-level resolver (runs when field is requested)
  User: {
    posts: async (parent, { first, after }, context) => {
      return context.dataSources.posts.findByUserId(parent.id, { first, after });
    },
    // Simple field mapping (usually not needed)
    email: (parent) => parent.email,
  },
};
```

### The N+1 Problem and DataLoader

Without DataLoader:
```
Query { users(first: 10) { posts { title } } }
# 1 query for users + 10 queries for posts = 11 queries
```

With DataLoader:
```typescript
import DataLoader from "dataloader";

// Create per-request DataLoader instances
function createLoaders() {
  return {
    postsByUserId: new DataLoader<string, Post[]>(async (userIds) => {
      // Single batched query: SELECT * FROM posts WHERE user_id IN (...)
      const posts = await db.posts.findMany({
        where: { userId: { in: [...userIds] } },
      });

      // Map results back to input order
      const postsByUser = new Map<string, Post[]>();
      for (const post of posts) {
        const existing = postsByUser.get(post.userId) || [];
        existing.push(post);
        postsByUser.set(post.userId, existing);
      }

      return userIds.map((id) => postsByUser.get(id) || []);
    }),

    userById: new DataLoader<string, User | null>(async (ids) => {
      const users = await db.users.findMany({
        where: { id: { in: [...ids] } },
      });
      const userMap = new Map(users.map((u) => [u.id, u]));
      return ids.map((id) => userMap.get(id) || null);
    }),
  };
}

// In resolver
const resolvers = {
  User: {
    posts: (parent, args, context) => {
      return context.loaders.postsByUserId.load(parent.id);
    },
  },
  Post: {
    author: (parent, args, context) => {
      return context.loaders.userById.load(parent.authorId);
    },
  },
};
```

## Authentication and Authorization

### Context Setup

```typescript
// Server setup - extract user from token
const server = new ApolloServer({
  typeDefs,
  resolvers,
  context: async ({ req }) => {
    const token = req.headers.authorization?.replace("Bearer ", "");
    let currentUser = null;

    if (token) {
      try {
        const decoded = await verifyJWT(token);
        currentUser = await db.users.findById(decoded.sub);
      } catch {
        // Invalid token - currentUser remains null
      }
    }

    return {
      currentUser,
      loaders: createLoaders(),
      dataSources: createDataSources(),
    };
  },
});
```

### Authorization Patterns

**Directive-based (schema-level):**

```graphql
directive @auth(requires: UserRole = MEMBER) on FIELD_DEFINITION | OBJECT

type Query {
  users: [User!]! @auth(requires: ADMIN)
  me: User! @auth
}

type User {
  email: Email! @auth(requires: ADMIN)  # Only admins see emails
  name: String!                          # Public field
}
```

```typescript
// Directive implementation
class AuthDirective extends SchemaDirectiveVisitor {
  visitFieldDefinition(field: GraphQLField<any, any>) {
    const requiredRole = this.args.requires;
    const originalResolve = field.resolve || defaultFieldResolver;

    field.resolve = async (parent, args, context, info) => {
      if (!context.currentUser) {
        throw new AuthenticationError("Authentication required");
      }
      if (requiredRole && context.currentUser.role !== requiredRole) {
        throw new ForbiddenError("Insufficient permissions");
      }
      return originalResolve(parent, args, context, info);
    };
  }
}
```

**Resolver-level authorization:**

```typescript
const resolvers = {
  Mutation: {
    deleteUser: async (_, { id }, context) => {
      // Only admins or the user themselves
      if (context.currentUser.role !== "ADMIN" && context.currentUser.id !== id) {
        throw new ForbiddenError("Cannot delete other users");
      }
      await context.dataSources.users.delete(id);
      return { deletedId: id, success: true };
    },
  },
};
```

## Error Handling

### GraphQL Error Format

```json
{
  "data": {
    "createUser": null
  },
  "errors": [
    {
      "message": "Email already exists",
      "locations": [{ "line": 2, "column": 3 }],
      "path": ["createUser"],
      "extensions": {
        "code": "CONFLICT",
        "field": "email",
        "timestamp": "2024-01-15T10:30:00Z"
      }
    }
  ]
}
```

### Error Classification

```typescript
// Custom error classes
class ValidationError extends GraphQLError {
  constructor(message: string, field: string) {
    super(message, {
      extensions: {
        code: "VALIDATION_ERROR",
        field,
      },
    });
  }
}

class BusinessRuleError extends GraphQLError {
  constructor(message: string, rule: string) {
    super(message, {
      extensions: {
        code: "BUSINESS_RULE_VIOLATION",
        rule,
      },
    });
  }
}

// Usage in resolvers
const resolvers = {
  Mutation: {
    createUser: async (_, { input }, context) => {
      if (!isValidEmail(input.email)) {
        throw new ValidationError("Invalid email format", "email");
      }

      const existing = await context.dataSources.users.findByEmail(input.email);
      if (existing) {
        throw new BusinessRuleError("Email already registered", "unique_email");
      }

      const user = await context.dataSources.users.create(input);
      return { user };
    },
  },
};
```

### Partial Success Pattern

```graphql
type Mutation {
  bulkCreateUsers(inputs: [CreateUserInput!]!): BulkCreateResult!
}

type BulkCreateResult {
  users: [User!]!
  errors: [CreateError!]!
  totalRequested: Int!
  totalCreated: Int!
}

type CreateError {
  index: Int!        # Which input failed
  message: String!
  code: String!
}
```

## Pagination

### Relay Connection Spec

```graphql
type Query {
  users(
    first: Int       # Forward pagination
    after: String    # Cursor
    last: Int        # Backward pagination
    before: String   # Cursor
  ): UserConnection!
}

type UserConnection {
  edges: [UserEdge!]!
  pageInfo: PageInfo!
  totalCount: Int      # Optional - expensive on large datasets
}

type UserEdge {
  node: User!
  cursor: String!      # Opaque cursor for this edge
}

type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}
```

### Implementation

```typescript
async function connectionFromQuery<T>(
  query: SelectQueryBuilder<T>,
  args: { first?: number; after?: string; last?: number; before?: string }
): Promise<Connection<T>> {
  const limit = args.first || args.last || 20;
  const maxLimit = 100;
  const effectiveLimit = Math.min(limit, maxLimit);

  let afterId: string | null = null;
  if (args.after) {
    afterId = Buffer.from(args.after, "base64").toString("utf8");
  }

  if (afterId) {
    query = query.where("id > :afterId", { afterId });
  }

  // Fetch one extra to determine hasNextPage
  const items = await query
    .orderBy("id", "ASC")
    .take(effectiveLimit + 1)
    .getMany();

  const hasNextPage = items.length > effectiveLimit;
  const nodes = hasNextPage ? items.slice(0, effectiveLimit) : items;

  const edges = nodes.map((node) => ({
    node,
    cursor: Buffer.from(node.id).toString("base64"),
  }));

  return {
    edges,
    pageInfo: {
      hasNextPage,
      hasPreviousPage: !!args.after,
      startCursor: edges[0]?.cursor || null,
      endCursor: edges[edges.length - 1]?.cursor || null,
    },
  };
}
```

### Simple Pagination (Alternative)

If Relay connections are overkill:

```graphql
type Query {
  users(limit: Int = 20, offset: Int = 0): UserList!
}

type UserList {
  items: [User!]!
  total: Int!
  hasMore: Boolean!
}
```

## Fragments, Interfaces, Unions

### Fragments (Client-Side Reuse)

```graphql
# Define reusable field sets
fragment UserBasic on User {
  id
  name
  avatar
}

fragment UserDetailed on User {
  ...UserBasic
  email
  role
  createdAt
  posts(first: 5) {
    edges {
      node {
        id
        title
      }
    }
  }
}

# Use in queries
query {
  me {
    ...UserDetailed
  }
  users(first: 10) {
    edges {
      node {
        ...UserBasic
      }
    }
  }
}
```

### Interfaces (Shared Fields)

```graphql
interface Node {
  id: ID!
}

interface Timestamped {
  createdAt: DateTime!
  updatedAt: DateTime!
}

type User implements Node & Timestamped {
  id: ID!
  name: String!
  createdAt: DateTime!
  updatedAt: DateTime!
}

type Post implements Node & Timestamped {
  id: ID!
  title: String!
  createdAt: DateTime!
  updatedAt: DateTime!
}

# Query any Node by ID
type Query {
  node(id: ID!): Node
}
```

### Unions (Polymorphic Results)

```graphql
union SearchResult = User | Post | Comment

type Query {
  search(query: String!): [SearchResult!]!
}

# Client query with type-specific fields
query {
  search(query: "graphql") {
    ... on User {
      id
      name
    }
    ... on Post {
      id
      title
      author { name }
    }
    ... on Comment {
      id
      body
      post { title }
    }
  }
}
```

```typescript
// Resolver must include __typename
const resolvers = {
  SearchResult: {
    __resolveType(obj: any) {
      if (obj.email) return "User";
      if (obj.title) return "Post";
      if (obj.body) return "Comment";
      return null;
    },
  },
};
```

## Schema Stitching and Federation

### Apollo Federation

Split schema across microservices:

```graphql
# Users service
type User @key(fields: "id") {
  id: ID!
  name: String!
  email: String!
}

type Query {
  user(id: ID!): User
  me: User
}
```

```graphql
# Orders service - extends User from another service
type User @key(fields: "id") {
  id: ID!
  orders: [Order!]!     # Added by this service
}

type Order @key(fields: "id") {
  id: ID!
  total: Int!
  status: OrderStatus!
  user: User!
}

type Query {
  order(id: ID!): Order
}
```

```typescript
// Orders service resolver
const resolvers = {
  User: {
    // Reference resolver - how to fetch User stub
    __resolveReference(ref: { id: string }, context: Context) {
      // Only need to resolve fields this service owns
      return { id: ref.id };
    },
    orders(user: { id: string }, _, context: Context) {
      return context.dataSources.orders.findByUserId(user.id);
    },
  },
};
```

### When to Federate

| Use Federation | Don't Federate |
|----------------|----------------|
| Multiple teams own different domains | Single team, single service |
| Independent deployment needed | Monolith or simple microservices |
| Schema > 500 types | Schema < 100 types |
| Different scaling requirements | Uniform load |

## Code-First vs Schema-First

### Schema-First (SDL)

Write `.graphql` files, generate types:

```graphql
# schema.graphql
type Query {
  user(id: ID!): User
}
```

```typescript
// Generated types (via graphql-codegen)
export type QueryUserArgs = { id: string };
export type QueryResolvers = {
  user?: Resolver<Maybe<User>, {}, Context, QueryUserArgs>;
};
```

**Pros**: Schema is the contract, readable, tooling-friendly
**Cons**: Types and schema can drift, boilerplate

### Code-First

Write TypeScript/Go, generate schema:

```typescript
// Using Pothos (TypeScript)
const builder = new SchemaBuilder<{
  Context: Context;
  Scalars: { DateTime: { Input: Date; Output: Date } };
}>({});

const UserType = builder.objectRef<User>("User").implement({
  fields: (t) => ({
    id: t.exposeID("id"),
    name: t.exposeString("name"),
    email: t.exposeString("email"),
    posts: t.field({
      type: [PostType],
      resolve: (user, _, context) =>
        context.loaders.postsByUserId.load(user.id),
    }),
  }),
});

builder.queryField("user", (t) =>
  t.field({
    type: UserType,
    nullable: true,
    args: { id: t.arg.id({ required: true }) },
    resolve: (_, { id }, context) =>
      context.dataSources.users.findById(id),
  })
);
```

**Pros**: Single source of truth, type-safe, refactor-friendly
**Cons**: Schema less visible, framework lock-in

### Recommendation

- **Schema-first**: Public APIs, multi-language teams, API-design-driven
- **Code-first**: TypeScript backends, rapid iteration, small teams

## Performance

### Query Complexity Analysis

```typescript
import { createComplexityLimitRule } from "graphql-validation-complexity";

const server = new ApolloServer({
  validationRules: [
    createComplexityLimitRule(1000, {
      scalarCost: 1,
      objectCost: 2,
      listFactor: 10,    // Multiplier for list fields
      formatErrorMessage: (cost: number) =>
        `Query too complex: cost ${cost} exceeds maximum 1000`,
    }),
  ],
});
```

### Depth Limiting

```typescript
import depthLimit from "graphql-depth-limit";

const server = new ApolloServer({
  validationRules: [
    depthLimit(7, { ignore: ["__schema"] }),  // Max 7 levels deep
  ],
});
```

### Persisted Queries

Lock down which queries can execute (production hardening):

```typescript
// Build step: extract queries from client code
// queries.json
{
  "abc123": "query GetUser($id: ID!) { user(id: $id) { id name email } }",
  "def456": "query ListUsers($first: Int) { users(first: $first) { edges { node { id name } } } }"
}

// Server: only allow registered queries
const server = new ApolloServer({
  persistedQueries: {
    cache: new InMemoryLRUCache(),
  },
  // In production, reject non-persisted queries
  allowBatchedHttpRequests: false,
});
```

### Automatic Persisted Queries (APQ)

```
# Client sends hash first (saves bandwidth)
POST /graphql
{
  "extensions": {
    "persistedQuery": {
      "version": 1,
      "sha256Hash": "abc123hash..."
    }
  },
  "variables": { "id": "user-123" }
}

# Server: "I don't have that hash"
{ "errors": [{ "message": "PersistedQueryNotFound" }] }

# Client retries with full query (cached for future)
POST /graphql
{
  "query": "query GetUser($id: ID!) { ... }",
  "extensions": {
    "persistedQuery": {
      "version": 1,
      "sha256Hash": "abc123hash..."
    }
  }
}
```

### Response Caching

```typescript
// Field-level cache hints
const resolvers = {
  Query: {
    user: (_, { id }, __, info) => {
      info.cacheControl.setCacheHint({ maxAge: 60, scope: "PRIVATE" });
      return fetchUser(id);
    },
    products: (_, __, ___, info) => {
      info.cacheControl.setCacheHint({ maxAge: 300, scope: "PUBLIC" });
      return fetchProducts();
    },
  },
};
```

## TypeScript and GraphQL

### Code Generation (graphql-codegen)

```yaml
# codegen.yml
schema: "./schema/**/*.graphql"
documents: "./src/**/*.{ts,tsx}"
generates:
  ./src/generated/types.ts:
    plugins:
      - typescript
      - typescript-resolvers
    config:
      contextType: "../context#Context"
      mappers:
        User: "../models#UserModel"

  ./src/generated/operations.ts:
    plugins:
      - typescript
      - typescript-operations
      - typescript-react-apollo    # For React hooks
```

```bash
npx graphql-codegen --watch
```

### Typed Client (urql / Apollo)

```typescript
// Auto-generated hook from codegen
import { useGetUserQuery } from "./generated/operations";

function UserProfile({ id }: { id: string }) {
  const [{ data, fetching, error }] = useGetUserQuery({
    variables: { id },
  });

  if (fetching) return <Loading />;
  if (error) return <Error error={error} />;

  // data.user is fully typed
  return <h1>{data.user.name}</h1>;
}
```

## When GraphQL Is Overkill

### Skip GraphQL When

- Simple CRUD with 1-2 clients (REST is simpler)
- File upload heavy (REST multipart is native)
- Real-time only (WebSocket/SSE is more direct)
- Team has no GraphQL experience and timeline is tight
- Caching is critical (HTTP caching with REST is free)
- Public API for third-party devs (REST has wider tooling)

### Use GraphQL When

- Multiple clients need different data shapes (mobile, web, TV)
- Deep, nested data with varied access patterns
- Rapid frontend iteration (no backend changes for new views)
- You have a federated microservice architecture
- Over-fetching or under-fetching is a real measured problem
- You can invest in proper tooling (codegen, DataLoader, complexity limits)

### GraphQL Anti-Patterns

| Anti-Pattern | Problem | Fix |
|--------------|---------|-----|
| No DataLoader | N+1 queries tank performance | Always batch with DataLoader |
| No depth/complexity limits | DoS via nested queries | Set limits before production |
| Huge input types | Mutations become dump trucks | Split into focused mutations |
| Business logic in resolvers | Untestable, duplicated | Thin resolvers, service layer |
| No error codes | Clients parse error strings | Use `extensions.code` |
| Schema-per-team with no coordination | Inconsistent naming, types | Schema governance / federation |
| Exposing DB schema as GraphQL schema | Coupling, security risk | Design for the client, not the DB |
