---
name: typescript-ops
description: "TypeScript type system, generics, utility types, strict mode, and ecosystem patterns. Use for: typescript, ts, type, generic, utility type, Partial, Pick, Omit, Record, Exclude, Extract, ReturnType, Parameters, keyof, typeof, infer, mapped type, conditional type, template literal type, discriminated union, type guard, type assertion, type narrowing, tsconfig, strict mode, declaration file, zod, valibot."
allowed-tools: "Read Write Bash"
related-skills: [react-ops, testing-ops]
---

# TypeScript Operations

Comprehensive TypeScript skill covering the type system, generics, and production patterns.

## Type Narrowing Decision Tree

```
How to narrow a type?
│
├─ Primitive type check
│  └─ typeof: typeof x === "string"
│
├─ Instance check
│  └─ instanceof: x instanceof Date
│
├─ Property existence
│  └─ in: "email" in user
│
├─ Discriminated union
│  └─ switch on literal field: switch (event.type)
│
├─ Null/undefined check
│  └─ Truthiness: if (x) or if (x != null)
│
├─ Custom logic
│  └─ Type predicate: function isUser(x: unknown): x is User
│
└─ Assertion (you know better than TS)
   └─ as: value as string (escape hatch, avoid when possible)
```

### Type Guard Example

```typescript
interface Dog { bark(): void; breed: string }
interface Cat { meow(): void; color: string }

function isDog(pet: Dog | Cat): pet is Dog {
    return "bark" in pet;
}

function handlePet(pet: Dog | Cat) {
    if (isDog(pet)) {
        pet.bark(); // TS knows it's Dog here
    } else {
        pet.meow(); // TS knows it's Cat here
    }
}
```

### Discriminated Unions

```typescript
type Result<T> =
    | { status: "success"; data: T }
    | { status: "error"; error: string }
    | { status: "loading" };

function handle<T>(result: Result<T>) {
    switch (result.status) {
        case "success": return result.data;     // data is available
        case "error":   throw new Error(result.error); // error is available
        case "loading": return null;
    }
    // Exhaustiveness check: result is `never` here
    const _exhaustive: never = result;
}
```

## Utility Types Cheat Sheet

| Utility | What It Does | Example |
|---------|-------------|---------|
| `Partial<T>` | All props optional | `Partial<User>` for update payloads |
| `Required<T>` | All props required | `Required<Config>` for validated config |
| `Readonly<T>` | All props readonly | `Readonly<State>` for immutable state |
| `Pick<T, K>` | Select specific props | `Pick<User, "id" \| "name">` |
| `Omit<T, K>` | Remove specific props | `Omit<User, "password">` |
| `Record<K, V>` | Object with typed keys/values | `Record<string, number>` |
| `Exclude<U, E>` | Remove types from union | `Exclude<Status, "deleted">` |
| `Extract<U, E>` | Keep types from union | `Extract<Event, { type: "click" }>` |
| `NonNullable<T>` | Remove null/undefined | `NonNullable<string \| null>` |
| `ReturnType<F>` | Function return type | `ReturnType<typeof fetchUser>` |
| `Parameters<F>` | Function params as tuple | `Parameters<typeof createUser>` |
| `Awaited<T>` | Unwrap Promise type | `Awaited<Promise<User>>` = `User` |

## Generic Patterns

### Constrained Generics

```typescript
// Basic constraint
function getProperty<T, K extends keyof T>(obj: T, key: K): T[K] {
    return obj[key];
}

// Multiple constraints
function merge<T extends object, U extends object>(a: T, b: U): T & U {
    return { ...a, ...b };
}

// Default generic type
type ApiResponse<T = unknown> = {
    data: T;
    status: number;
};
```

### Conditional Types

```typescript
// Basic conditional
type IsString<T> = T extends string ? true : false;

// infer keyword - extract inner type
type UnwrapPromise<T> = T extends Promise<infer U> ? U : T;
type UnwrapArray<T> = T extends (infer U)[] ? U : T;

// Distributive conditional (distributes over union)
type ToArray<T> = T extends any ? T[] : never;
// ToArray<string | number> = string[] | number[]

// Prevent distribution with wrapping
type ToArrayNonDist<T> = [T] extends [any] ? T[] : never;
// ToArrayNonDist<string | number> = (string | number)[]
```

### Mapped Types

```typescript
// Make all properties optional and nullable
type Nullable<T> = { [K in keyof T]: T[K] | null };

// Add prefix to keys
type Prefixed<T, P extends string> = {
    [K in keyof T as `${P}${Capitalize<string & K>}`]: T[K];
};
// Prefixed<{ name: string }, "get"> = { getName: string }

// Filter keys by value type
type StringKeys<T> = {
    [K in keyof T as T[K] extends string ? K : never]: T[K];
};
```

**Deep dive**: Load `./references/generics-patterns.md` for advanced type-level programming, recursive types, template literal types.

## tsconfig Quick Reference

```jsonc
{
    "compilerOptions": {
        // Strict mode (always enable)
        "strict": true,               // Enables all strict checks
        "noUncheckedIndexedAccess": true,  // arr[0] is T | undefined

        // Module system
        "module": "esnext",           // or "nodenext" for Node
        "moduleResolution": "bundler", // or "nodenext"
        "esModuleInterop": true,

        // Output
        "target": "es2022",
        "outDir": "dist",
        "declaration": true,          // Generate .d.ts
        "sourceMap": true,

        // Paths
        "baseUrl": ".",
        "paths": { "@/*": ["src/*"] },

        // Strictness extras
        "noUnusedLocals": true,
        "noUnusedParameters": true,
        "noFallthroughCasesInSwitch": true,
        "forceConsistentCasingInFileNames": true
    },
    "include": ["src"],
    "exclude": ["node_modules", "dist"]
}
```

**Deep dive**: Load `./references/config-strict.md` for strict mode migration, monorepo config, project references.

## Common Gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| `any` leaks | `any` disables type checking for everything it touches | Use `unknown` + narrowing instead |
| `as` assertions hide bugs | Assertion doesn't check at runtime | Use type guards or validation (Zod) |
| `enum` quirks | Numeric enums are not type-safe, reverse mappings confuse | Use `as const` objects or string literal unions |
| `object` vs `Record` vs `{}` | `{}` matches any non-null value, `object` is non-primitive | Use `Record<string, unknown>` for "any object" |
| Array index access | `arr[999]` returns `T` not `T \| undefined` by default | Enable `noUncheckedIndexedAccess` |
| Optional vs undefined | `{ x?: string }` allows missing key, `{ x: string \| undefined }` requires key | Be explicit about which you mean |
| `!` non-null assertion | Silences null checks, no runtime effect | Use `?? defaultValue` or proper null check |
| Structural typing surprise | `{ a: 1, b: 2 }` assignable to `{ a: number }` | Use branded types for nominal typing |

## Branded / Nominal Types

```typescript
// Prevent accidentally mixing types that are structurally identical
type UserId = string & { readonly __brand: "UserId" };
type OrderId = string & { readonly __brand: "OrderId" };

function createUserId(id: string): UserId { return id as UserId; }

function getUser(id: UserId) { /* ... */ }

const userId = createUserId("u-123");
const orderId = "o-456" as OrderId;

getUser(userId);   // OK
getUser(orderId);  // Error: OrderId not assignable to UserId
```

## Runtime Validation (Zod)

```typescript
import { z } from "zod";

// Define schema
const UserSchema = z.object({
    id: z.number(),
    name: z.string().min(1),
    email: z.string().email(),
    role: z.enum(["admin", "user"]),
    settings: z.object({
        theme: z.enum(["light", "dark"]).default("light"),
    }).optional(),
});

// Infer type from schema
type User = z.infer<typeof UserSchema>;

// Validate
const user = UserSchema.parse(untrustedData);       // throws on invalid
const result = UserSchema.safeParse(untrustedData);  // returns { success, data/error }
```

## Reference Files

Load these for deep-dive topics. Each is self-contained.

| Reference | When to Load |
|-----------|-------------|
| `./references/type-system.md` | Advanced types, branded types, type-level programming, satisfies operator |
| `./references/generics-patterns.md` | Generic constraints, conditional types, mapped types, template literals, recursive types |
| `./references/utility-types.md` | All built-in utility types with examples, custom utility types |
| `./references/config-strict.md` | tsconfig deep dive, strict mode migration, project references, monorepo setup |
| `./references/ecosystem.md` | Zod/Valibot, type-safe API clients, ORM types, testing with Vitest |

## See Also

- `testing-ops` - Cross-language testing strategies
- `ci-cd-ops` - TypeScript CI pipelines, type checking in CI
