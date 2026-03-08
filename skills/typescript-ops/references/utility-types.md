# TypeScript Utility Types Reference

## Table of Contents

1. [Built-in Utility Types](#built-in-utility-types)
2. [Custom Utility Types](#custom-utility-types)
3. [Type-Safe Object Operations](#type-safe-object-operations)
4. [Array/Tuple Utilities](#arraytuple-utilities)
5. [Function Utilities](#function-utilities)

---

## Built-in Utility Types

### Object Shape Utilities

```typescript
// Partial<T> - Make all properties optional
interface User { id: string; name: string; email: string; }
type UpdateUser = Partial<User>; // { id?: string; name?: string; email?: string }

function updateUser(id: string, patch: Partial<User>): User { /* ... */ }

// Required<T> - Make all properties required
interface Config { host?: string; port?: number; debug?: boolean; }
type StrictConfig = Required<Config>; // { host: string; port: number; debug: boolean }

// Readonly<T> - Make all properties readonly
type ImmutableUser = Readonly<User>; // { readonly id: string; readonly name: string; ... }
const frozen: ImmutableUser = { id: '1', name: 'Alice', email: 'a@b.com' };
// frozen.name = 'Bob'; // Error: cannot assign to 'name' because it is a read-only property

// Record<K, T> - Create an object type with keys K and values T
type UserMap    = Record<string, User>;
type StatusMap  = Record<'active' | 'inactive' | 'banned', number>;
type HttpStatus = Record<200 | 404 | 500, string>;

// Pick<T, K> - Select a subset of properties
type UserPreview = Pick<User, 'id' | 'name'>; // { id: string; name: string }
type Credentials = Pick<User, 'email'>;         // { email: string }

// Omit<T, K> - Exclude specific properties
type PublicUser = Omit<User, 'email'>;   // { id: string; name: string }
type NewUser    = Omit<User, 'id'>;      // { name: string; email: string }
```

### Union Manipulation Utilities

```typescript
// Exclude<T, U> - Remove U from union T
type NonBoolean  = Exclude<string | number | boolean, boolean>; // string | number
type NonNullish  = Exclude<string | null | undefined, null | undefined>; // string
type NonString   = Exclude<string | number | boolean, string>; // number | boolean

// Extract<T, U> - Keep only members of T that are assignable to U
type OnlyStrings = Extract<string | number | boolean, string>; // string
type Primitives  = Extract<string | number | { id: string }, string | number>; // string | number

// NonNullable<T> - Remove null and undefined from T
type SafeString = NonNullable<string | null | undefined>; // string
type SafeUser   = NonNullable<User | null | undefined>;   // User
```

### Function Utilities

```typescript
function fetchData(url: string, timeout: number, headers: Record<string, string>): Promise<unknown> {
  return fetch(url);
}

// ReturnType<T> - Get the return type of a function type
type FetchResult = ReturnType<typeof fetchData>;     // Promise<unknown>
type StringLength = ReturnType<typeof String.prototype.indexOf>; // number

// Parameters<T> - Get parameters as a tuple type
type FetchParams = Parameters<typeof fetchData>;
// [url: string, timeout: number, headers: Record<string, string>]

// Call a function with stored parameters
function withDefaults<T extends (...args: unknown[]) => unknown>(
  fn: T,
  defaults: Partial<Parameters<T>>
) { /* ... */ }

// ConstructorParameters<T> - Get constructor parameter types
class HttpClient {
  constructor(baseUrl: string, timeout: number) {}
}
type HttpArgs = ConstructorParameters<typeof HttpClient>; // [string, number]

// InstanceType<T> - Get the type of a class instance
type ClientInstance = InstanceType<typeof HttpClient>; // HttpClient

// ThisParameterType<T> - Extract the type of 'this'
function greet(this: { name: string }, greeting: string): string {
  return `${greeting}, ${this.name}`;
}
type GreetThis = ThisParameterType<typeof greet>; // { name: string }

// OmitThisParameter<T> - Remove this parameter from function type
type GreetFn = OmitThisParameter<typeof greet>; // (greeting: string) => string
```

### Awaited and String Utilities

```typescript
// Awaited<T> - Recursively unwrap Promise
type A = Awaited<Promise<string>>;          // string
type B = Awaited<Promise<Promise<number>>>; // number
type C = Awaited<string | Promise<number>>; // string | number

async function loadData(): Promise<User[]> { return []; }
type LoadResult = Awaited<ReturnType<typeof loadData>>; // User[]

// String manipulation (compile-time only, no runtime effect)
type UpperName = Uppercase<'hello'>;      // 'HELLO'
type LowerName = Lowercase<'WORLD'>;      // 'world'
type CapName   = Capitalize<'alice'>;     // 'Alice'
type UnCapName = Uncapitalize<'Hello'>;   // 'hello'

// Useful for generating method names
type Methods<T extends string> = `get${Capitalize<T>}` | `set${Capitalize<T>}`;
type NameMethods = Methods<'name' | 'age'>; // 'getName' | 'getAge' | 'setName' | 'setAge'
```

---

## Custom Utility Types

### DeepReadonly

```typescript
type DeepReadonly<T> =
  T extends (infer U)[]
    ? ReadonlyArray<DeepReadonly<U>>
    : T extends object
    ? { readonly [K in keyof T]: DeepReadonly<T[K]> }
    : T;

interface AppState {
  user: { id: string; profile: { name: string; bio: string } };
  settings: { theme: string; notifications: boolean[] };
}

type FrozenState = DeepReadonly<AppState>;
declare const state: FrozenState;
// state.user.profile.name = 'x'; // Error - deeply readonly
```

### DeepPartial

```typescript
type DeepPartial<T> =
  T extends (infer U)[]
    ? DeepPartial<U>[]
    : T extends object
    ? { [K in keyof T]?: DeepPartial<T[K]> }
    : T;

// Useful for deep merge / patch operations
function deepMerge<T>(target: T, patch: DeepPartial<T>): T {
  if (typeof patch !== 'object' || patch === null) return patch as T;
  const result = { ...target };
  for (const key of Object.keys(patch) as (keyof T)[]) {
    const val = patch[key as keyof typeof patch];
    if (val !== undefined) {
      (result[key] as unknown) = typeof val === 'object' && val !== null
        ? deepMerge(result[key] as object, val as DeepPartial<object>)
        : val;
    }
  }
  return result;
}
```

### Nullable and Optional

```typescript
type Nullable<T> = T | null;
type Optional<T> = T | undefined;
type NullableOptional<T> = T | null | undefined;

// Require at least one of specified keys
type RequireAtLeastOne<T, Keys extends keyof T = keyof T> =
  Omit<T, Keys> &
  { [K in Keys]-?: Required<Pick<T, K>> & Partial<Omit<T, K>> }[Keys];

// Require exactly one of specified keys
type RequireExactlyOne<T, Keys extends keyof T = keyof T> =
  Omit<T, Keys> &
  { [K in Keys]: Required<Pick<T, K>> & { [O in Exclude<Keys, K>]?: never } }[Keys];
```

### Merge and UnionToIntersection

```typescript
// Merge two types, second overrides first
type Merge<T, U> = Omit<T, keyof U> & U;

type A = { id: string; name: string; active: boolean };
type B = { name: number; extra: string }; // name changes type
type C = Merge<A, B>; // { id: string; active: boolean; name: number; extra: string }

// Convert a union to an intersection
type UnionToIntersection<U> =
  (U extends unknown ? (x: U) => void : never) extends (x: infer I) => void
    ? I
    : never;

type IntersectedABC = UnionToIntersection<{ a: string } | { b: number } | { c: boolean }>;
// { a: string } & { b: number } & { c: boolean }

// Prettify - flatten intersection types for readable IDE output
type Prettify<T> = { [K in keyof T]: T[K] } & {};
```

### Exact and StrictOmit

```typescript
// Ensure no extra properties (useful in function params)
type Exact<T, Shape> = T extends Shape
  ? Exclude<keyof T, keyof Shape> extends never
    ? T
    : never
  : never;

// StrictOmit: errors if K is not in T (unlike Omit which silently ignores)
type StrictOmit<T, K extends keyof T> = Omit<T, K>;
```

---

## Type-Safe Object Operations

### Type-Safe pick

```typescript
function pick<T extends object, K extends keyof T>(obj: T, keys: K[]): Pick<T, K> {
  return keys.reduce((acc, key) => {
    acc[key] = obj[key];
    return acc;
  }, {} as Pick<T, K>);
}

const user: User = { id: '1', name: 'Alice', email: 'a@b.com' };
const preview = pick(user, ['id', 'name']); // { id: string; name: string }
// TypeScript knows preview has only 'id' and 'name'
```

### Type-Safe omit

```typescript
function omit<T extends object, K extends keyof T>(obj: T, keys: K[]): Omit<T, K> {
  const result = { ...obj };
  keys.forEach((key) => delete result[key]);
  return result as Omit<T, K>;
}

const publicUser = omit(user, ['email']); // { id: string; name: string }
```

### Type-Safe merge

```typescript
function merge<T extends object, U extends object>(base: T, override: U): Merge<T, U> {
  return { ...base, ...override } as Merge<T, U>;
}

type Merge<T, U> = Omit<T, keyof U> & U;
```

### Type-Safe diff (keys present in T but not U)

```typescript
type Diff<T, U> = Pick<T, Exclude<keyof T, keyof U>>;

type OnlyInA = Diff<{ a: string; b: number; c: boolean }, { b: number; d: string }>;
// { a: string; c: boolean }
```

---

## Array/Tuple Utilities

### Head, Tail, Last, Reverse

```typescript
// First element of a tuple
type Head<T extends unknown[]> =
  T extends [infer H, ...unknown[]] ? H : never;

// All but first element
type Tail<T extends unknown[]> =
  T extends [unknown, ...infer R] ? R : never;

// Last element of a tuple
type Last<T extends unknown[]> =
  T extends [...unknown[], infer L] ? L : never;

// Reverse a tuple
type Reverse<T extends unknown[], Acc extends unknown[] = []> =
  T extends [infer Head, ...infer Rest]
    ? Reverse<Rest, [Head, ...Acc]>
    : Acc;

type H = Head<[string, number, boolean]>; // string
type T = Tail<[string, number, boolean]>; // [number, boolean]
type L = Last<[string, number, boolean]>; // boolean
type R = Reverse<[1, 2, 3]>;             // [3, 2, 1]
```

### Flatten Types

```typescript
// Flatten one level
type Flatten<T extends unknown[]> =
  T extends (infer U)[] ? U : T;

type F = Flatten<string[][]>; // string[]

// Flatten nested arrays recursively
type DeepFlatten<T> =
  T extends (infer U)[]
    ? U extends unknown[]
      ? DeepFlatten<U>
      : U
    : T;

type Deep = DeepFlatten<string[][][]>; // string
```

### Zip Two Tuples

```typescript
type Zip<T extends unknown[], U extends unknown[]> =
  T extends [infer TH, ...infer TR]
    ? U extends [infer UH, ...infer UR]
      ? [[TH, UH], ...Zip<TR, UR>]
      : []
    : [];

type Zipped = Zip<[1, 2, 3], ['a', 'b', 'c']>;
// [[1, 'a'], [2, 'b'], [3, 'c']]
```

### Length and Indices

```typescript
type Length<T extends readonly unknown[]> = T['length'];

// Generate numeric union of indices
type Indices<T extends readonly unknown[]> =
  Exclude<keyof T, keyof []>;

type Len = Length<[1, 2, 3]>; // 3
type Idx = Indices<['a', 'b', 'c']>; // '0' | '1' | '2'
```

---

## Function Utilities

### Promisify Type

```typescript
// Convert a callback-style function type to one returning a Promise
type Promisify<T extends (...args: unknown[]) => unknown> =
  T extends (...args: infer A) => infer R
    ? R extends Promise<unknown>
      ? T
      : (...args: A) => Promise<Awaited<R>>
    : never;

type SyncFn = (x: number) => string;
type AsyncFn = Promisify<SyncFn>; // (x: number) => Promise<string>
```

### Curry Type

```typescript
type Head<T extends unknown[]> = T extends [infer H, ...unknown[]] ? H : never;
type Tail<T extends unknown[]> = T extends [unknown, ...infer R] ? R : never;

type Curried<TArgs extends unknown[], TReturn> =
  TArgs extends []
    ? TReturn
    : (arg: Head<TArgs>) => Curried<Tail<TArgs>, TReturn>;

declare function curry<TArgs extends unknown[], TReturn>(
  fn: (...args: TArgs) => TReturn
): Curried<TArgs, TReturn>;

const add = curry((a: number, b: number) => a + b);
const inc = add(1);     // Curried<[number], number> = (b: number) => number
const two = inc(1);     // number
```

### Overload Helper

```typescript
// Extract all overload signatures as a union
type Overloads<T extends (...args: unknown[]) => unknown> =
  T extends {
    (...args: infer A1): infer R1;
    (...args: infer A2): infer R2;
    (...args: infer A3): infer R3;
    (...args: infer A4): infer R4;
  }
    ? ((...args: A1) => R1) | ((...args: A2) => R2) | ((...args: A3) => R3) | ((...args: A4) => R4)
    : T extends {
        (...args: infer A1): infer R1;
        (...args: infer A2): infer R2;
        (...args: infer A3): infer R3;
      }
    ? ((...args: A1) => R1) | ((...args: A2) => R2) | ((...args: A3) => R3)
    : T extends { (...args: infer A1): infer R1; (...args: infer A2): infer R2 }
    ? ((...args: A1) => R1) | ((...args: A2) => R2)
    : T;
```

### Memoize with Type Safety

```typescript
type AnyFn = (...args: unknown[]) => unknown;

function memoize<T extends AnyFn>(fn: T): T {
  const cache = new Map<string, ReturnType<T>>();
  return ((...args: Parameters<T>): ReturnType<T> => {
    const key = JSON.stringify(args);
    if (cache.has(key)) return cache.get(key) as ReturnType<T>;
    const result = fn(...args) as ReturnType<T>;
    cache.set(key, result);
    return result;
  }) as T;
}

const expensiveCalc = memoize((a: number, b: number): number => a * b);
expensiveCalc(2, 3); // 6 - computed
expensiveCalc(2, 3); // 6 - cached
```
