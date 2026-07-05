---
name: typescript-ops
description: "TypeScript type system, generics, utility types, strict mode, and ecosystem patterns. Use for: typescript, ts, type, generic, utility type, Partial, Pick, Omit, Record, Exclude, Extract, ReturnType, Parameters, keyof, typeof, infer, mapped type, conditional type, template literal type, discriminated union, type guard, type assertion, type narrowing, tsconfig, strict mode, declaration file, zod, valibot."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: react-ops, testing-ops
---

# TypeScript Operations

Comprehensive TypeScript skill covering the type system, generics, and production patterns.

> Ecosystem facts verified as of 2026-07-05 (TypeScript 6, Zod 4, Valibot 1).

**Staleness check:** `python scripts/check-typescript-facts.py --offline` asserts the
catalogued version-bearing facts (TypeScript major, zod, valibot) are still named in the
prose and the dated currency note above is present; run `--live` to confirm each package's
npm major still matches the documented major. Catalog: `assets/typescript-facts.json`.

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

## Modern Language Features (TypeScript 5.x → 6.0)

| Feature | Since | What It Gives You |
|---------|-------|-------------------|
| `satisfies` operator | 4.9 | Check a value against a type without widening it |
| Standard (TC39) decorators | 5.0 | `@decorator` on classes/methods without `experimentalDecorators` |
| `const` type parameters | 5.0 | `function f<const T>(x: T)` infers literal types without `as const` at call sites |
| `using` declarations | 5.2 | Explicit resource management (`Symbol.dispose`), auto-cleanup at scope exit |
| Inferred type predicates | 5.5 | `arr.filter(x => x !== null)` narrows without a hand-written `x is T` guard |
| `verbatimModuleSyntax` | 5.0 | Enforces `import type` for type-only imports — replaces `importsNotUsedAsValues` |

```typescript
// const type parameters (5.0) - literal inference without as const
function routes<const T extends readonly string[]>(paths: T): T { return paths; }
const r = routes(["/home", "/about"]); // readonly ["/home", "/about"], not string[]

// using declarations (5.2) - deterministic cleanup
function readConfig() {
    using file = openFile("config.json"); // file[Symbol.dispose]() runs at scope exit
    return parse(file.contents);
}

// Inferred type predicates (5.5) - no manual guard needed
const names = ["a", null, "b"].filter(x => x !== null); // string[], not (string | null)[]
```

### TypeScript 6.0 (Current Major)

TS 6.0 is the last release on the JavaScript-based compiler — it exists to bridge to the
native (Go) compiler in TS 7, so its headline is stricter, modernised defaults:

- **`strict: true` is the default** — a tsconfig that never set it now gets full strict checks
- **Defaults modernised**: `module: esnext`, `target: es2025`; `es2025` lib ships types for Temporal, `Map.getOrInsert`, `RegExp.escape`
- **Legacy options removed**: `moduleResolution: classic`; `module: amd/umd/system/none`; minimum `target` is now ES2015 (`es5` deprecated)
- **Interop always on**: `esModuleInterop` / `allowSyntheticDefaultImports` can no longer be disabled
- New `--stableTypeOrdering` flag eases 6.0 → 7.0 migration diffing

## tsconfig Quick Reference

```jsonc
{
    "compilerOptions": {
        // Strict mode (default in TS 6; state it explicitly anyway)
        "strict": true,               // Enables all strict checks
        "noUncheckedIndexedAccess": true,  // arr[0] is T | undefined

        // Module system (TS 6 defaults to module: esnext; interop is always on)
        "module": "esnext",           // or "nodenext" for Node
        "moduleResolution": "bundler", // or "nodenext"

        // Output (TS 6 defaults target to es2025; min supported is es2015)
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

## Runtime Validation (Zod 4)

```typescript
import { z } from "zod";

// Define schema (Zod 4: string formats are top-level - z.email(), not z.string().email())
const UserSchema = z.object({
    id: z.number(),
    name: z.string().min(1),
    email: z.email(),
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

**Zod 4 changes to know** (if you learned Zod 3): string formats moved to the top level
(`z.email()`, `z.uuid()`, `z.url()` — the `z.string().email()` method form is deprecated);
error customisation unified under a single `error` param (`invalid_type_error` /
`required_error` dropped); much faster parsing and a tree-shakeable `zod/mini` entry point.

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
