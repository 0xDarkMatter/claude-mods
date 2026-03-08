# TypeScript Ecosystem Reference

## Table of Contents

1. [Runtime Validation](#runtime-validation)
2. [Type-Safe API Clients](#type-safe-api-clients)
3. [ORM Types](#orm-types)
4. [Testing with Types](#testing-with-types)
5. [Type-Safe Routing](#type-safe-routing)
6. [Effect](#effect)
7. [ts-pattern](#ts-pattern)
8. [Type Challenges](#type-challenges)

---

## Runtime Validation

### Use Zod for Schema Validation with Type Inference

Zod is the most widely adopted runtime validation library. Define a schema once; infer the TypeScript type from it.

```typescript
import { z } from 'zod';

// Define schema
const UserSchema = z.object({
  id: z.string().uuid(),
  name: z.string().min(1).max(100),
  email: z.string().email(),
  age: z.number().int().min(0).max(150).optional(),
  role: z.enum(['admin', 'user', 'moderator']),
  createdAt: z.coerce.date(),
});

// Infer TypeScript type from schema - single source of truth
type User = z.infer<typeof UserSchema>;
// { id: string; name: string; email: string; age?: number; role: 'admin' | 'user' | 'moderator'; createdAt: Date }

// Parse and validate (throws ZodError on failure)
const user = UserSchema.parse(rawData);

// Safe parse (returns success/failure object, never throws)
const result = UserSchema.safeParse(rawData);
if (result.success) {
  console.log(result.data); // typed as User
} else {
  console.error(result.error.flatten()); // ZodError with friendly message structure
}
```

### Apply Zod Transforms and Refinements

```typescript
const PasswordSchema = z
  .string()
  .min(8, 'Password must be at least 8 characters')
  .regex(/[A-Z]/, 'Password must contain an uppercase letter')
  .regex(/[0-9]/, 'Password must contain a number');

// Transform: parse then convert
const DateStringSchema = z.string().transform((s) => new Date(s));
type DateValue = z.infer<typeof DateStringSchema>; // Date (output type after transform)
// Input type is string; output type is Date

// Refine: validate with custom logic
const EvenNumberSchema = z.number().refine(
  (n) => n % 2 === 0,
  { message: 'Number must be even' }
);

// Discriminated union (Zod version)
const ApiResponseSchema = z.discriminatedUnion('status', [
  z.object({ status: z.literal('success'), data: z.unknown() }),
  z.object({ status: z.literal('error'), message: z.string() }),
]);
type ApiResponse = z.infer<typeof ApiResponseSchema>;
```

### Use Valibot as a Tree-Shakeable Alternative

Valibot has an almost identical API to Zod but is tree-shakeable by design, resulting in much smaller bundles for edge/browser deployments.

```typescript
import * as v from 'valibot';

const UserSchema = v.object({
  id: v.pipe(v.string(), v.uuid()),
  name: v.pipe(v.string(), v.minLength(1), v.maxLength(100)),
  email: v.pipe(v.string(), v.email()),
  role: v.picklist(['admin', 'user', 'moderator']),
});

type User = v.InferOutput<typeof UserSchema>;

const result = v.safeParse(UserSchema, rawData);
if (result.success) {
  console.log(result.output); // typed as User
}
```

### Compare Zod vs Valibot

| Concern | Zod | Valibot |
|---------|-----|---------|
| Bundle size | ~13 kB min+gz | ~0.5-2 kB (tree-shaken) |
| API style | Method chaining | Pipe/function composition |
| Ecosystem | Larger (more integrations) | Smaller but growing |
| Best for | Node.js / full-stack | Edge / browser |
| Async validation | `z.refine(async ...)` | `v.pipeAsync(...)` |

---

## Type-Safe API Clients

### Build a Type-Safe Fetch Wrapper

```typescript
type ApiResponse<T> =
  | { ok: true; data: T; status: number }
  | { ok: false; error: string; status: number };

async function apiFetch<T>(
  url: string,
  schema: { parse: (data: unknown) => T },
  init?: RequestInit
): Promise<ApiResponse<T>> {
  try {
    const response = await fetch(url, init);
    const json: unknown = await response.json();

    if (!response.ok) {
      return { ok: false, error: String(json), status: response.status };
    }

    const data = schema.parse(json);
    return { ok: true, data, status: response.status };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : 'Unknown error', status: 0 };
  }
}

// Usage with Zod schema
const UsersSchema = z.array(UserSchema);
const result = await apiFetch('/api/users', UsersSchema);
if (result.ok) {
  result.data; // User[]
}
```

### Use openapi-typescript for Contract-First APIs

```bash
# Generate TypeScript types from an OpenAPI spec
npx openapi-typescript ./openapi.yaml -o ./src/types/api.d.ts
# or from a URL
npx openapi-typescript https://api.example.com/openapi.json -o ./src/types/api.d.ts
```

```typescript
import type { paths, components } from './types/api.d.ts';

// Use generated types in a typed client
type GetUserParams = paths['/users/{id}']['get']['parameters'];
type GetUserResponse = paths['/users/{id}']['get']['responses']['200']['content']['application/json'];
type User = components['schemas']['User'];
```

### Add tRPC for End-to-End Type Safety

```typescript
// server/router.ts
import { initTRPC } from '@trpc/server';
import { z } from 'zod';

const t = initTRPC.create();

export const appRouter = t.router({
  user: t.router({
    getById: t.procedure
      .input(z.object({ id: z.string() }))
      .query(async ({ input }) => {
        return await db.user.findUnique({ where: { id: input.id } });
      }),

    create: t.procedure
      .input(z.object({ name: z.string(), email: z.string().email() }))
      .mutation(async ({ input }) => {
        return await db.user.create({ data: input });
      }),
  }),
});

export type AppRouter = typeof appRouter;

// client/trpc.ts
import { createTRPCProxyClient, httpBatchLink } from '@trpc/client';
import type { AppRouter } from '../server/router';

const trpc = createTRPCProxyClient<AppRouter>({
  links: [httpBatchLink({ url: 'http://localhost:3000/trpc' })],
});

// Fully type-safe - input and output types inferred from router
const user = await trpc.user.getById.query({ id: '123' });
// user is typed as the return type of the resolver - no manual typing needed
```

---

## ORM Types

### Generate Types with Prisma

Prisma generates complete TypeScript types from the schema file.

```prisma
// prisma/schema.prisma
model User {
  id        String   @id @default(cuid())
  email     String   @unique
  name      String?
  posts     Post[]
  createdAt DateTime @default(now())
}
```

```typescript
import { PrismaClient } from '@prisma/client';
// Prisma generates:
// - PrismaClient with typed query methods
// - User, Post, etc. model types
// - UserCreateInput, UserUpdateInput, UserWhereInput, etc.

const db = new PrismaClient();

// Fully typed queries
const user = await db.user.findUniqueOrThrow({
  where: { email: 'alice@example.com' },
  include: { posts: true },
});
// user: User & { posts: Post[] }

// Use generated input types
import type { Prisma } from '@prisma/client';

async function createUser(data: Prisma.UserCreateInput) {
  return db.user.create({ data });
}

// Select subsets for performance
type UserPreview = Prisma.UserGetPayload<{
  select: { id: true; name: true; email: true };
}>;
```

### Write Type-Safe Queries with Drizzle ORM

Drizzle is a SQL-first ORM where types flow from the schema definition.

```typescript
import { pgTable, text, integer, timestamp } from 'drizzle-orm/pg-core';
import { drizzle } from 'drizzle-orm/node-postgres';
import { eq } from 'drizzle-orm';

const users = pgTable('users', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  email: text('email').notNull().unique(),
  age: integer('age'),
  createdAt: timestamp('created_at').defaultNow(),
});

// Infer types directly from table definition
type User = typeof users.$inferSelect;    // for SELECT results
type NewUser = typeof users.$inferInsert; // for INSERT data

const db = drizzle(pool);

// Type-safe queries - IDE autocomplete on column names
const allUsers = await db.select().from(users);
// allUsers: User[]

const alice = await db.select().from(users).where(eq(users.email, 'alice@example.com'));
// alice: User[]

await db.insert(users).values({ id: '1', name: 'Alice', email: 'alice@example.com' });
// Type error if required fields are missing
```

### Query with Kysely for SQL-First Type Safety

Kysely provides type-safe query building without code generation.

```typescript
import { Kysely, PostgresDialect } from 'kysely';

interface Database {
  users: { id: string; name: string; email: string; age: number | null };
  posts: { id: string; userId: string; title: string; content: string };
}

const db = new Kysely<Database>({ dialect: new PostgresDialect({ pool }) });

const users = await db
  .selectFrom('users')
  .select(['id', 'name', 'email'])
  .where('age', '>', 18)
  .execute();
// users: Array<{ id: string; name: string; email: string }>
```

---

## Testing with Types

### Use expectTypeOf in Vitest

```typescript
import { expectTypeOf, test } from 'vitest';

test('identity function preserves type', () => {
  function identity<T>(value: T): T { return value; }

  expectTypeOf(identity('hello')).toEqualTypeOf<string>();
  expectTypeOf(identity(42)).toEqualTypeOf<number>();
  expectTypeOf(identity).toBeFunction();
  expectTypeOf(identity).parameter(0).toBeString();
});

test('Result type narrows correctly', () => {
  type Result<T> = { ok: true; value: T } | { ok: false; error: string };

  function ok<T>(value: T): Result<T> { return { ok: true, value }; }
  function err<T>(error: string): Result<T> { return { ok: false, error }; }

  expectTypeOf(ok('data')).toEqualTypeOf<Result<string>>();
  expectTypeOf(err<number>('oops')).toEqualTypeOf<Result<number>>();
});
```

### Use assertType for Compile-Time Checks

```typescript
import { assertType, test } from 'vitest';

test('types are correct', () => {
  // assertType<T>(value) asserts value matches type T at compile time
  // (no runtime effect - type-only check)
  assertType<string>('hello');
  assertType<number>(42);

  // @ts-expect-error assertions that should fail
  // @ts-expect-error
  assertType<string>(42); // fails: 42 is not string
});
```

### Use tsd for Testing Declaration Files

`tsd` is dedicated to testing `.d.ts` files. It checks that type definitions behave correctly.

```typescript
// index.test-d.ts
import { expectType, expectError, expectAssignable } from 'tsd';
import { getUser, createUser } from './index.js';

// Check return types
expectType<Promise<User>>(getUser('123'));

// Check that invalid calls produce errors
expectError(getUser(123)); // Error: number not assignable to string

// Check assignability (less strict than equality)
expectAssignable<{ id: string }>(await getUser('1'));
```

```json
// package.json
{
  "scripts": {
    "test:types": "tsd"
  },
  "tsd": {
    "directory": "test"
  }
}
```

---

## Type-Safe Routing

### Use Next.js Typed Routes

Next.js 13+ supports experimental typed routes that validate `href` values.

```json
// next.config.js
{
  "experimental": {
    "typedRoutes": true
  }
}
```

```typescript
import Link from 'next/link';

// TypeScript validates the href against your actual routes
<Link href="/about">About</Link>            // OK if /about exists
<Link href="/users/[id]">User</Link>        // Error: must pass actual id
<Link href={{ pathname: '/users/[id]', params: { id: '1' } }}>User</Link> // OK
```

### Build Type-Safe Path Parameters

```typescript
// Generic route parameter extractor
type ExtractParams<T extends string> =
  T extends `${string}:${infer Param}/${infer Rest}`
    ? { [K in Param]: string } & ExtractParams<Rest>
    : T extends `${string}:${infer Param}`
    ? { [K in Param]: string }
    : Record<string, never>;

type Prettify<T> = { [K in keyof T]: T[K] } & {};

function createRoute<T extends string>(
  template: T
): { path: T; build(params: Prettify<ExtractParams<T>>): string } {
  return {
    path: template,
    build(params) {
      return Object.entries(params).reduce(
        (path, [key, value]) => path.replace(`:${key}`, value as string),
        template
      );
    },
  };
}

const userRoute = createRoute('/users/:userId/posts/:postId');
const url = userRoute.build({ userId: '1', postId: '42' }); // '/users/1/posts/42'
// TypeScript error if userId or postId is missing
```

---

## Effect

### Use Effect-TS for Typed Functional Error Handling

Effect models computations as `Effect<Value, Error, Requirements>`. Errors are part of the type, not thrown.

```typescript
import { Effect, pipe } from 'effect';

// Define typed errors
class UserNotFoundError {
  readonly _tag = 'UserNotFoundError';
  constructor(readonly id: string) {}
}

class DatabaseError {
  readonly _tag = 'DatabaseError';
  constructor(readonly message: string) {}
}

// Effect<User, UserNotFoundError | DatabaseError, never>
// Value: User, Error: UserNotFoundError | DatabaseError, Requirements: none
const getUser = (id: string): Effect.Effect<User, UserNotFoundError | DatabaseError> =>
  Effect.tryPromise({
    try: () => db.user.findUniqueOrThrow({ where: { id } }),
    catch: (e) =>
      e instanceof Error && e.message.includes('No User found')
        ? new UserNotFoundError(id)
        : new DatabaseError(String(e)),
  });

// Compose effects with pipe
const program = pipe(
  getUser('123'),
  Effect.map((user) => user.name),
  Effect.catchTag('UserNotFoundError', (e) =>
    Effect.succeed(`User ${e.id} not found`)
  ),
  // DatabaseError is still in the error channel - must be handled or propagated
);

// Run the effect
const result = await Effect.runPromise(program);
```

---

## ts-pattern

### Match Exhaustively with ts-pattern

`ts-pattern` provides pattern matching with full TypeScript type narrowing.

```typescript
import { match, P } from 'ts-pattern';

type ApiState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'success'; data: User[] }
  | { status: 'error'; error: Error };

function render(state: ApiState): string {
  return match(state)
    .with({ status: 'idle' },    () => 'Ready')
    .with({ status: 'loading' }, () => 'Loading...')
    .with({ status: 'success', data: P.select() }, (data) =>
      `Loaded ${data.length} users`
    )
    .with({ status: 'error', error: P.select() }, (error) =>
      `Error: ${error.message}`
    )
    .exhaustive(); // Compile error if a variant is unhandled
}

// Pattern guards
const result = match(value)
  .with(P.number.gt(100), (n) => `Big: ${n}`)
  .with(P.number.lt(0),   (n) => `Negative: ${n}`)
  .with(P.number,          (n) => `Normal: ${n}`)
  .with(P.string,          (s) => `String: ${s}`)
  .otherwise(() => 'Unknown');

// Nested matching
const message = match(response)
  .with({ type: 'error', code: P.union(401, 403) }, () => 'Unauthorized')
  .with({ type: 'error', code: 404 },               () => 'Not Found')
  .with({ type: 'error' },                           () => 'Server Error')
  .with({ type: 'success' },                         () => 'OK')
  .exhaustive();
```

---

## Type Challenges

### Practice Advanced Types Effectively

The `type-challenges` repository (github.com/type-challenges/type-challenges) provides 200+ graded exercises.

```typescript
// Example: Implement Readonly<T> from scratch
type MyReadonly<T> = {
  readonly [K in keyof T]: T[K];
};

// Example: Implement Pick<T, K>
type MyPick<T, K extends keyof T> = {
  [P in K]: T[P];
};

// Example: Implement Exclude<T, U>
type MyExclude<T, U> = T extends U ? never : T;

// Example: Implement ReturnType<T>
type MyReturnType<T> = T extends (...args: unknown[]) => infer R ? R : never;

// Example: Deep Readonly
type DeepReadonly<T> = keyof T extends never
  ? T
  : { readonly [K in keyof T]: DeepReadonly<T[K]> };
```

### Use the TypeScript Playground

The TypeScript Playground (typescriptlang.org/play) supports:
- Sharing type puzzles via URL
- Viewing emitted JavaScript
- Checking against multiple TS versions
- Running code in browser

### Recommended Learning Resources

| Resource | Focus |
|----------|-------|
| `type-challenges` on GitHub | Exercises from easy to extreme |
| Matt Pocock's Total TypeScript | Tutorials and workshops |
| TypeScript Deep Dive (basarat) | Comprehensive free book |
| Official TS Handbook | Language reference |
| tsdocs.dev | Browse type definitions for any npm package |
| typescript-eslint.io | Type-aware lint rules |

### Set Up a Type Testing Playground Locally

```bash
mkdir ts-playground && cd ts-playground
npm init -y
npm install -D typescript tsx @types/node

cat > tsconfig.json << 'EOF'
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler"
  }
}
EOF

# Write type experiments
cat > playground.ts << 'EOF'
type Test = /* your type here */;
type Expect<T extends true> = T;
type Equal<A, B> = A extends B ? B extends A ? true : false : false;

type Case1 = Expect<Equal<Test, ExpectedType>>;
EOF

npx tsx playground.ts
```
