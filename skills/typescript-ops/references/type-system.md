# TypeScript Type System Reference

## Table of Contents

1. [Literal Types](#literal-types)
2. [Discriminated Unions](#discriminated-unions)
3. [Branded/Nominal Types](#brandednominal-types)
4. [Template Literal Types](#template-literal-types)
5. [Recursive Types](#recursive-types)
6. [satisfies Operator](#satisfies-operator)
7. [Type Assertions](#type-assertions)
8. [Declaration Merging](#declaration-merging)
9. [Type-Level Arithmetic](#type-level-arithmetic)
10. [Variance](#variance)

---

## Literal Types

### Understand String, Number, and Boolean Literals

Literal types restrict a value to one specific value rather than the broader primitive type.

```typescript
// String literal
type Direction = 'north' | 'south' | 'east' | 'west';
type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE' | 'PATCH';

// Number literal
type DiceRoll = 1 | 2 | 3 | 4 | 5 | 6;
type HttpSuccess = 200 | 201 | 204;

// Boolean literal
type Truthy = true;
type Falsy = false;

// Mixed literal union
type Status = 'pending' | 'fulfilled' | 'rejected';
type Result = 0 | 1 | -1;

function move(direction: Direction): void {
  console.log(`Moving ${direction}`);
}

move('north');  // OK
move('up');     // Error: Argument of type '"up"' is not assignable to parameter of type 'Direction'
```

### Use const Assertions to Preserve Literal Types

Without `as const`, TypeScript widens literals to their primitive types. With it, literals are preserved.

```typescript
// Without as const - types are widened
const config = {
  endpoint: '/api',   // string
  retries: 3,         // number
  methods: ['GET', 'POST'], // string[]
};

// With as const - all literals preserved
const CONFIG = {
  endpoint: '/api',   // '/api'
  retries: 3,         // 3
  methods: ['GET', 'POST'], // readonly ['GET', 'POST']
} as const;

type Endpoint = typeof CONFIG.endpoint;  // '/api'
type Retry   = typeof CONFIG.retries;    // 3
type Methods = typeof CONFIG.methods[number]; // 'GET' | 'POST'

// as const on arrays
const ROLES = ['admin', 'user', 'moderator'] as const;
type Role = typeof ROLES[number]; // 'admin' | 'user' | 'moderator'

// as const on function arguments
function configure<T extends object>(opts: T): Readonly<T> {
  return Object.freeze(opts);
}

const opts = configure({ debug: true, port: 3000 } as const);
// opts.debug is true (not boolean), opts.port is 3000 (not number)
```

### Derive Union Types from const Arrays

```typescript
const HTTP_METHODS = ['GET', 'POST', 'PUT', 'DELETE'] as const;
type HttpMethod = typeof HTTP_METHODS[number];

// Enum alternative using as const object
const Color = {
  Red: 'red',
  Green: 'green',
  Blue: 'blue',
} as const;

type Color = typeof Color[keyof typeof Color]; // 'red' | 'green' | 'blue'
```

---

## Discriminated Unions

### Build Discriminated Unions with a Shared Literal Property

Every variant shares a common property (the discriminant) with a unique literal type.

```typescript
type Shape =
  | { kind: 'circle'; radius: number }
  | { kind: 'rectangle'; width: number; height: number }
  | { kind: 'triangle'; base: number; height: number };

function area(shape: Shape): number {
  switch (shape.kind) {
    case 'circle':
      return Math.PI * shape.radius ** 2;
    case 'rectangle':
      return shape.width * shape.height;
    case 'triangle':
      return 0.5 * shape.base * shape.height;
  }
}
```

### Implement Exhaustiveness Checking with never

When all union variants are handled, the remaining type is `never`. Passing `never` to a function that expects `never` causes a type error when a new variant is added.

```typescript
function assertNever(value: never, message?: string): never {
  throw new Error(message ?? `Unhandled discriminated union member: ${JSON.stringify(value)}`);
}

type NetworkState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'success'; data: string }
  | { status: 'error'; error: Error };

function handleState(state: NetworkState): string {
  switch (state.status) {
    case 'idle':    return 'Waiting...';
    case 'loading': return 'Loading...';
    case 'success': return state.data;
    case 'error':   return state.error.message;
    default:        return assertNever(state); // Compile error if case is missing
  }
}
```

### Model Result Types as Discriminated Unions

```typescript
type Ok<T>  = { ok: true;  value: T };
type Err<E> = { ok: false; error: E };
type Result<T, E = Error> = Ok<T> | Err<E>;

function divide(a: number, b: number): Result<number, string> {
  if (b === 0) return { ok: false, error: 'Division by zero' };
  return { ok: true, value: a / b };
}

const result = divide(10, 2);
if (result.ok) {
  console.log(result.value); // number
} else {
  console.error(result.error); // string
}
```

---

## Branded/Nominal Types

### Create Branded Types to Prevent Type Confusion

TypeScript uses structural typing: two types with the same shape are interchangeable. Branding adds a phantom property to make them nominally distinct.

```typescript
type Brand<T, B extends string> = T & { readonly __brand: B };

type UserId   = Brand<string, 'UserId'>;
type OrderId  = Brand<string, 'OrderId'>;
type Email    = Brand<string, 'Email'>;
type Dollars  = Brand<number, 'Dollars'>;
type Cents    = Brand<number, 'Cents'>;

// Without branding these are all just 'string' - interchangeable and unsafe.
// With branding they are distinct.
function getUser(id: UserId): void { /* ... */ }
function getOrder(id: OrderId): void { /* ... */ }

declare const userId: UserId;
declare const orderId: OrderId;

getUser(userId);   // OK
getUser(orderId);  // Error: Argument of type 'OrderId' is not assignable to parameter of type 'UserId'
```

### Write Validation Functions That Return Branded Types

```typescript
function brandUserId(raw: string): UserId {
  return raw as UserId;
}

function parseEmail(raw: string): Email {
  if (!/^[^@]+@[^@]+\.[^@]+$/.test(raw)) {
    throw new Error(`Invalid email: ${raw}`);
  }
  return raw as Email;
}

function parseDollars(amount: number): Dollars {
  if (amount < 0) throw new Error('Dollars cannot be negative');
  return amount as Dollars;
}

// Use in domain logic - type system enforces correct usage
function sendInvoice(to: Email, amount: Dollars): void { /* ... */ }
```

### Use Opaque Types via Unique Symbol (Advanced)

For stricter encapsulation, use unique symbols as the brand key.

```typescript
declare const _brand: unique symbol;

type Opaque<T, Tag> = T & { readonly [_brand]: Tag };

type PositiveInt = Opaque<number, 'PositiveInt'>;

function toPositiveInt(n: number): PositiveInt {
  if (!Number.isInteger(n) || n <= 0) {
    throw new Error(`Expected positive integer, got ${n}`);
  }
  return n as PositiveInt;
}
```

---

## Template Literal Types

### Build Type-Safe String Patterns

Template literal types compose string literals at the type level.

```typescript
type EventName<T extends string> = `on${Capitalize<T>}`;
type ClickEvent = EventName<'click'>;   // 'onClick'
type ChangeEvent = EventName<'change'>; // 'onChange'

type CSSProperty = 'margin' | 'padding';
type CSSUnit = 'px' | 'em' | 'rem' | '%';
type CSSValue = `${number}${CSSUnit}`; // '10px', '1.5em', etc.

// Route parameter extraction
type RouteParam<T extends string> =
  T extends `${string}:${infer Param}/${infer Rest}`
    ? Param | RouteParam<Rest>
    : T extends `${string}:${infer Param}`
    ? Param
    : never;

type Params = RouteParam<'/users/:userId/posts/:postId'>;
// 'userId' | 'postId'
```

### Use String Manipulation Types

```typescript
type Uppercased = Uppercase<'hello world'>;   // 'HELLO WORLD'
type Lowercased = Lowercase<'HELLO WORLD'>;   // 'hello world'
type Capitalized = Capitalize<'hello'>;       // 'Hello'
type Uncapitalized = Uncapitalize<'Hello'>;   // 'hello'

// Build getter/setter types
type Getter<T extends string> = `get${Capitalize<T>}`;
type Setter<T extends string> = `set${Capitalize<T>}`;

type FieldName = 'name' | 'age' | 'email';
type Getters = { [K in FieldName as Getter<K>]: string };
// { getName: string; getAge: string; getEmail: string }

// Build event handler types from object keys
type EventHandlers<T> = {
  [K in keyof T as `on${Capitalize<string & K>}Change`]: (value: T[K]) => void;
};

interface FormFields { name: string; age: number; }
type FormHandlers = EventHandlers<FormFields>;
// { onNameChange: (value: string) => void; onAgeChange: (value: number) => void }
```

---

## Recursive Types

### Define the JSON Type

```typescript
type JsonPrimitive = string | number | boolean | null;
type JsonArray    = JsonValue[];
type JsonObject   = { [key: string]: JsonValue };
type JsonValue    = JsonPrimitive | JsonArray | JsonObject;

// Usage
const data: JsonValue = {
  name: 'Alice',
  scores: [1, 2, 3],
  address: { city: 'NYC', zip: null },
};
```

### Implement Deep Readonly and Deep Partial

```typescript
type DeepReadonly<T> = T extends (infer U)[]
  ? ReadonlyArray<DeepReadonly<U>>
  : T extends object
  ? { readonly [K in keyof T]: DeepReadonly<T[K]> }
  : T;

type DeepPartial<T> = T extends (infer U)[]
  ? DeepPartial<U>[]
  : T extends object
  ? { [K in keyof T]?: DeepPartial<T[K]> }
  : T;

interface Config {
  server: { host: string; port: number };
  database: { url: string; poolSize: number };
}

type ReadonlyConfig = DeepReadonly<Config>;
// server.host and all nested props are readonly

type PartialConfig = DeepPartial<Config>;
// All nested props optional
```

### Build Path Types for Safe Object Access

```typescript
type PathOf<T, Sep extends string = '.'> =
  T extends object
    ? {
        [K in keyof T]: K extends string
          ? T[K] extends object
            ? K | `${K}${Sep}${PathOf<T[K], Sep>}`
            : K
          : never;
      }[keyof T]
    : never;

type ValueAt<T, P extends string> =
  P extends `${infer K}.${infer Rest}`
    ? K extends keyof T
      ? ValueAt<T[K], Rest>
      : never
    : P extends keyof T
    ? T[P]
    : never;

interface User {
  id: string;
  profile: { name: string; address: { city: string } };
}

type UserPath = PathOf<User>;
// 'id' | 'profile' | 'profile.name' | 'profile.address' | 'profile.address.city'

type CityType = ValueAt<User, 'profile.address.city'>; // string
```

---

## satisfies Operator

### Validate Type Without Widening

The `satisfies` operator checks that a value matches a type while preserving the most specific type.

```typescript
// Problem without satisfies:
type Palette = Record<string, [number, number, number] | string>;

const palette1: Palette = {
  red: [255, 0, 0],
  green: '#00ff00',
};
// palette1.red is [number, number, number] | string - information lost

// With satisfies:
const palette2 = {
  red: [255, 0, 0],
  green: '#00ff00',
} satisfies Palette;
// palette2.red is [number, number, number] - specific type preserved
// palette2.green is string - specific type preserved

palette2.red.map(v => v * 2); // OK - TypeScript knows it's an array
palette2.green.toUpperCase(); // OK - TypeScript knows it's a string
```

### Combine satisfies with as const

```typescript
const routes = {
  home: '/',
  about: '/about',
  user: '/users/:id',
} as const satisfies Record<string, `/${string}`>;

// Routes values are literal types, not string
type HomeRoute = typeof routes.home; // '/'
```

### Use satisfies for Configuration Objects

```typescript
interface PluginConfig {
  name: string;
  version: string;
  hooks?: {
    beforeBuild?: () => void;
    afterBuild?: () => void;
  };
}

const myPlugin = {
  name: 'my-plugin',
  version: '1.0.0',
  hooks: {
    beforeBuild: () => console.log('building...'),
  },
} satisfies PluginConfig;

// myPlugin.name is 'my-plugin' not string
// TypeScript checks shape against PluginConfig at definition site
```

---

## Type Assertions

### Understand When Assertions Are Safe

Type assertions (`as T`) override TypeScript's type inference. They are safe only when you have external information the compiler cannot verify.

```typescript
// SAFE: narrowing after a runtime check
function processInput(input: unknown): string {
  if (typeof input === 'string') {
    return input; // narrowed, no assertion needed
  }
  // We know from domain logic this is always serializable
  return String(input);
}

// SAFE: DOM API returns Element | null, but we know the element exists
const canvas = document.getElementById('canvas') as HTMLCanvasElement;

// UNSAFE: asserting unrelated types
const num = 42 as unknown as string; // compiles, crashes at runtime
```

### Use Double Assertion as Escape Hatch

When TypeScript refuses an assertion because types don't overlap, cast through `unknown`.

```typescript
// Only do this when you have proof the cast is correct
function forceType<T>(value: unknown): T {
  return value as T;
}

// Explicit escape: cast through unknown
const risky = someValue as unknown as TargetType;
```

### Prefer Type Guards Over Assertions

```typescript
// BAD: assertion with no runtime check
function getUser(data: unknown): User {
  return data as User; // unsafe, no verification
}

// GOOD: type guard with runtime verification
function isUser(data: unknown): data is User {
  return (
    typeof data === 'object' &&
    data !== null &&
    'id' in data &&
    typeof (data as Record<string, unknown>).id === 'string' &&
    'name' in data &&
    typeof (data as Record<string, unknown>).name === 'string'
  );
}

function getUser(data: unknown): User {
  if (!isUser(data)) throw new Error('Invalid user data');
  return data; // safe, narrowed by type guard
}
```

---

## Declaration Merging

### Merge Interfaces to Extend Third-Party Types

```typescript
// Original interface from a library
interface Request {
  method: string;
  url: string;
}

// Your augmentation - merges with above
interface Request {
  user?: { id: string; role: string };
  requestId: string;
}

// Result: Request has method, url, user, requestId
```

### Augment Modules to Add Types to External Packages

```typescript
// express-augment.d.ts
import 'express';

declare module 'express' {
  interface Request {
    user?: { id: string; role: 'admin' | 'user' };
    sessionId: string;
  }
}
```

### Augment Global Scope

```typescript
// global.d.ts
declare global {
  interface Window {
    analytics: {
      track(event: string, properties?: Record<string, unknown>): void;
    };
  }

  interface Array<T> {
    // Add a custom method to all arrays
    groupBy<K extends string>(keyFn: (item: T) => K): Record<K, T[]>;
  }
}

export {}; // Required to make this a module (not a script)
```

---

## Type-Level Arithmetic

### Measure Tuple Lengths

```typescript
type Length<T extends readonly unknown[]> = T['length'];

type Three = Length<[1, 2, 3]>; // 3
type Zero  = Length<[]>;         // 0
```

### Build a Recursive Counter

```typescript
// Build a tuple of length N, then read its length
type BuildTuple<N extends number, T extends unknown[] = []> =
  T['length'] extends N ? T : BuildTuple<N, [...T, unknown]>;

type Add<A extends number, B extends number> =
  Length<[...BuildTuple<A>, ...BuildTuple<B>]>;

type Sum = Add<3, 4>; // 7

type Subtract<A extends number, B extends number> =
  BuildTuple<A> extends [...BuildTuple<B>, ...infer Rest]
    ? Length<Rest>
    : never;

type Diff = Subtract<7, 3>; // 4
```

---

## Variance

### Understand Covariance and Contravariance

- **Covariant**: A `Producer<Dog>` is assignable to `Producer<Animal>` (output position)
- **Contravariant**: A `Consumer<Animal>` is assignable to `Consumer<Dog>` (input position)
- **Invariant**: Neither assignment is safe

```typescript
// Covariant: return type position
type Producer<out T> = () => T;

declare let animalProducer: Producer<Animal>;
declare let dogProducer: Producer<Dog>;

animalProducer = dogProducer; // OK - Dog is a subtype of Animal

// Contravariant: parameter type position
type Consumer<in T> = (value: T) => void;

declare let animalConsumer: Consumer<Animal>;
declare let dogConsumer: Consumer<Dog>;

dogConsumer = animalConsumer; // OK - Consumer<Animal> handles any Animal including Dog
animalConsumer = dogConsumer; // Error - Consumer<Dog> can't handle all Animals
```

### Apply in/out Variance Annotations (TypeScript 4.7+)

```typescript
interface Animal { name: string; }
interface Dog extends Animal { breed: string; }

// Explicitly mark variance for clarity and performance
interface ReadableStream<out T> {   // covariant - only produces T
  read(): T;
}

interface WritableStream<in T> {    // contravariant - only consumes T
  write(value: T): void;
}

interface Transform<in TInput, out TOutput> { // bivariant
  transform(input: TInput): TOutput;
}
```

### Recognize Function Parameter Bivariance Trap

```typescript
// strictFunctionTypes catches this
type Callback = (event: MouseEvent) => void;
type Handler  = (event: Event) => void;

// With strictFunctionTypes: NOT assignable (correct)
// Without strictFunctionTypes: assignable (unsafe)
```
