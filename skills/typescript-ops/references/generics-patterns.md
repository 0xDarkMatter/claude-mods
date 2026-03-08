# TypeScript Generics Patterns Reference

## Table of Contents

1. [Generic Functions](#generic-functions)
2. [Generic Classes](#generic-classes)
3. [Generic Interfaces](#generic-interfaces)
4. [Conditional Types](#conditional-types)
5. [Mapped Types](#mapped-types)
6. [Template Literal Types in Generics](#template-literal-types-in-generics)
7. [Variadic Tuple Types](#variadic-tuple-types)
8. [Higher-Kinded Types](#higher-kinded-types)
9. [Builder Pattern](#builder-pattern)
10. [Common Generic Patterns](#common-generic-patterns)

---

## Generic Functions

### Infer Type Parameters From Arguments

TypeScript infers type parameters from call-site arguments. Prefer inference over explicit type args.

```typescript
// Inferred: T = string from the argument
function identity<T>(value: T): T {
  return value;
}
const s = identity('hello'); // T inferred as string

// Constraint: T must have a length property
function longest<T extends { length: number }>(a: T, b: T): T {
  return a.length >= b.length ? a : b;
}
longest('alice', 'bob');         // OK - strings have length
longest([1, 2, 3], [1, 2]);     // OK - arrays have length
longest({ length: 5 }, { length: 3 }); // OK

// Multiple type parameters with relationship constraint
function getProperty<T, K extends keyof T>(obj: T, key: K): T[K] {
  return obj[key];
}

const user = { id: 1, name: 'Alice', active: true };
getProperty(user, 'name');   // string
getProperty(user, 'active'); // boolean
getProperty(user, 'foo');    // Error: 'foo' is not a key of typeof user
```

### Use Default Type Parameters

```typescript
// Default type parameter when not specified
function createArray<T = string>(length: number, fill: T): T[] {
  return Array(length).fill(fill);
}

const strings = createArray(3, 'x');   // string[] - T inferred
const numbers = createArray(3, 0);     // number[] - T inferred
const explicit = createArray<boolean>(3, true); // boolean[]

// Useful in generic components/hooks
interface PaginatedResponse<T = unknown> {
  data: T[];
  total: number;
  page: number;
}
```

---

## Generic Classes

### Parameterize Class Behavior

```typescript
class Stack<T> {
  private items: T[] = [];

  push(item: T): void {
    this.items.push(item);
  }

  pop(): T | undefined {
    return this.items.pop();
  }

  peek(): T | undefined {
    return this.items[this.items.length - 1];
  }

  get size(): number {
    return this.items.length;
  }
}

const numStack = new Stack<number>();
numStack.push(1);
numStack.push(2);
const top = numStack.pop(); // number | undefined
```

### Recognize the Static Members Limitation

Static members cannot reference a class's type parameters. The type parameter belongs to an instance.

```typescript
class Container<T> {
  value: T;  // OK - instance member

  constructor(value: T) {
    this.value = value;
  }

  // static defaultValue: T; // Error: static members can't reference type parameters

  // Workaround: use a separate factory type or factory method
  static create<U>(value: U): Container<U> {
    return new Container(value);
  }
}
```

---

## Generic Interfaces

### Implement the Repository Pattern

```typescript
interface Repository<T, ID = string> {
  findById(id: ID): Promise<T | null>;
  findAll(filter?: Partial<T>): Promise<T[]>;
  save(entity: T): Promise<T>;
  delete(id: ID): Promise<void>;
}

interface User {
  id: string;
  name: string;
  email: string;
}

class UserRepository implements Repository<User, string> {
  async findById(id: string): Promise<User | null> { /* ... */ return null; }
  async findAll(filter?: Partial<User>): Promise<User[]> { /* ... */ return []; }
  async save(entity: User): Promise<User> { /* ... */ return entity; }
  async delete(id: string): Promise<void> { /* ... */ }
}
```

### Implement the Factory Pattern

```typescript
interface Factory<T, TArgs extends unknown[] = []> {
  create(...args: TArgs): T;
}

class ConnectionFactory implements Factory<Connection, [string, number]> {
  create(host: string, port: number): Connection {
    return new Connection(host, port);
  }
}
```

---

## Conditional Types

### Distribute Over Union Types

Conditional types distribute over naked type parameters in unions.

```typescript
// Distributes: IsString<string | number> = IsString<string> | IsString<number>
type IsString<T> = T extends string ? true : false;
type Test = IsString<string | number>; // true | false = boolean

// To prevent distribution, wrap in a tuple
type IsStringExact<T> = [T] extends [string] ? true : false;
type Test2 = IsStringExact<string | number>; // false
```

### Use infer to Extract Types

```typescript
// Extract the element type from an array
type UnpackArray<T> = T extends (infer U)[] ? U : T;
type Item = UnpackArray<string[]>; // string
type Same = UnpackArray<number>;   // number

// Extract return type (equivalent to built-in ReturnType)
type MyReturnType<T> = T extends (...args: unknown[]) => infer R ? R : never;

// Extract the resolved value of a Promise
type Awaited<T> = T extends Promise<infer U> ? Awaited<U> : T;
type Value = Awaited<Promise<Promise<string>>>; // string

// Extract first parameter type
type FirstParam<T> = T extends (first: infer F, ...rest: unknown[]) => unknown ? F : never;
type F = FirstParam<(a: string, b: number) => void>; // string

// Extract constructor instance type
type InstanceOf<T> = T extends new (...args: unknown[]) => infer I ? I : never;
```

### Nest Conditional Types for Complex Logic

```typescript
type TypeName<T> =
  T extends string  ? 'string'  :
  T extends number  ? 'number'  :
  T extends boolean ? 'boolean' :
  T extends null    ? 'null'    :
  T extends undefined ? 'undefined' :
  T extends Function ? 'function' :
  'object';

type A = TypeName<string>;   // 'string'
type B = TypeName<() => void>; // 'function'
type C = TypeName<{ a: 1 }>;  // 'object'

// Filter a union: keep only string keys from a type
type StringKeys<T> = {
  [K in keyof T]: T[K] extends string ? K : never;
}[keyof T];

interface Mixed { id: string; count: number; name: string; active: boolean; }
type OnlyStringFields = StringKeys<Mixed>; // 'id' | 'name'
```

---

## Mapped Types

### Remap Keys with the as Clause

```typescript
// Prefix all keys
type Prefixed<T, P extends string> = {
  [K in keyof T as `${P}${Capitalize<string & K>}`]: T[K];
};

interface User { id: string; name: string; }
type PrefixedUser = Prefixed<User, 'user'>; // { userId: string; userName: string }

// Filter keys by value type
type PickByValue<T, V> = {
  [K in keyof T as T[K] extends V ? K : never]: T[K];
};

interface Config { debug: boolean; port: number; host: string; verbose: boolean; }
type BooleanConfig = PickByValue<Config, boolean>; // { debug: boolean; verbose: boolean }
```

### Apply Modifiers with + and -

```typescript
// Add readonly and optional
type Immutable<T> = {
  +readonly [K in keyof T]+?: T[K];
};

// Remove readonly and optional (make mutable and required)
type Mutable<T> = {
  -readonly [K in keyof T]-?: T[K];
};

interface Optional {
  readonly id?: string;
  readonly name?: string;
}

type Concrete = Mutable<Optional>; // { id: string; name: string }
```

### Combine Mapped and Conditional Types

```typescript
// Make only specific keys optional
type MakeOptional<T, K extends keyof T> = Omit<T, K> & Partial<Pick<T, K>>;

interface Post {
  id: string;
  title: string;
  content: string;
  publishedAt: Date;
}

type DraftPost = MakeOptional<Post, 'id' | 'publishedAt'>;
// { title: string; content: string; id?: string; publishedAt?: Date }
```

---

## Template Literal Types in Generics

### Build Type-Safe Event Emitters

```typescript
type EventMap = {
  userCreated: { userId: string };
  orderPlaced: { orderId: string; total: number };
  sessionExpired: { sessionId: string };
};

type EventListener<TMap, TEvent extends keyof TMap> =
  (event: TMap[TEvent]) => void;

type Emitter<TMap> = {
  on<TEvent extends keyof TMap>(
    event: TEvent,
    listener: EventListener<TMap, TEvent>
  ): void;
  emit<TEvent extends keyof TMap>(event: TEvent, data: TMap[TEvent]): void;
};

declare const emitter: Emitter<EventMap>;

emitter.on('userCreated', (e) => console.log(e.userId));   // OK
emitter.on('orderPlaced', (e) => console.log(e.total));    // OK
emitter.emit('userCreated', { userId: '123' });             // OK
emitter.emit('userCreated', { orderId: '123' });            // Error: wrong shape
```

### Extract Route Parameters

```typescript
type RouteParams<T extends string> =
  T extends `${string}:${infer Param}/${infer Rest}`
    ? { [K in Param | keyof RouteParams<Rest>]: string }
    : T extends `${string}:${infer Param}`
    ? { [K in Param]: string }
    : Record<string, never>;

function buildRoute<T extends string>(
  template: T,
  params: RouteParams<T>
): string {
  return Object.entries(params).reduce(
    (path, [key, value]) => path.replace(`:${key}`, value as string),
    template
  );
}

const url = buildRoute('/users/:userId/posts/:postId', {
  userId: '1',
  postId: '42',
}); // '/users/1/posts/42'
```

---

## Variadic Tuple Types

### Spread Tuples for Function Composition

```typescript
// Concatenate two tuple types
type Concat<T extends unknown[], U extends unknown[]> = [...T, ...U];
type T1 = Concat<[1, 2], [3, 4]>; // [1, 2, 3, 4]

// Strongly typed pipe/compose
type Pipe<T extends ((...args: unknown[]) => unknown)[]> =
  T extends [infer First, ...infer Rest]
    ? First extends (...args: infer A) => infer R
      ? Rest extends []
        ? (...args: A) => R
        : Pipe<[(...args: A) => R, ...Extract<Rest, ((...args: unknown[]) => unknown)[]>]>
      : never
    : never;

// Prepend and append to tuples
type Prepend<T, Tuple extends unknown[]> = [T, ...Tuple];
type Append<Tuple extends unknown[], T>  = [...Tuple, T];

type WithFirst = Prepend<string, [number, boolean]>; // [string, number, boolean]
type WithLast  = Append<[string, number], boolean>;   // [string, number, boolean]
```

### Build Type-Safe curry

```typescript
type Head<T extends unknown[]> = T extends [infer H, ...unknown[]] ? H : never;
type Tail<T extends unknown[]> = T extends [unknown, ...infer R] ? R : never;

type Curry<TArgs extends unknown[], TReturn> =
  TArgs extends []
    ? TReturn
    : (arg: Head<TArgs>) => Curry<Tail<TArgs>, TReturn>;

declare function curry<TArgs extends unknown[], TReturn>(
  fn: (...args: TArgs) => TReturn
): Curry<TArgs, TReturn>;

const add = curry((a: number, b: number, c: number) => a + b + c);
const add5 = add(5);          // Curry<[number, number], number>
const add5and3 = add5(3);     // Curry<[number], number>
const result = add5and3(2);   // number = 10
```

---

## Higher-Kinded Types

### Emulate HKT with Interface Lookup

TypeScript doesn't natively support higher-kinded types, but they can be emulated with a registry pattern.

```typescript
// Define a type-level registry for type constructors
interface HKTRegistry {
  // Registered types go here via module augmentation
}

type HKT = keyof HKTRegistry;
type Apply<F extends HKT, A> = HKTRegistry[F] extends { type: unknown }
  ? (HKTRegistry[F] & { arg: A })['type']
  : never;

// Register Array as a type constructor
declare module './hkt' {
  interface HKTRegistry {
    Array: { type: Array<this['arg']> };
  }
}

// Functor interface using HKT
interface Functor<F extends HKT> {
  map<A, B>(fa: Apply<F, A>, f: (a: A) => B): Apply<F, B>;
}
```

---

## Builder Pattern

### Track Builder State in the Type System

```typescript
type BuilderState = {
  hasName: boolean;
  hasAge: boolean;
};

type Builder<State extends BuilderState, T = {}> = {
  setName(name: string): Builder<State & { hasName: true }, T & { name: string }>;
  setAge(age: number): Builder<State & { hasAge: true }, T & { age: number }>;
} & (State['hasName'] extends true
  ? State['hasAge'] extends true
    ? { build(): T }
    : {}
  : {});

declare function createBuilder(): Builder<{ hasName: false; hasAge: false }>;

const builder = createBuilder();
const user = builder.setName('Alice').setAge(30).build();
// user: { name: string } & { age: number }

// Compile errors:
// builder.build() - Error: build() not available until required fields set
// builder.setName('Alice').build() - Error: age not set
```

### Use Fluent Interface with Immutable Type Accumulation

```typescript
class QueryBuilder<T extends Record<string, unknown> = Record<string, never>> {
  private conditions: string[] = [];
  private selectedFields: string[] = [];

  select<K extends string>(field: K): QueryBuilder<T & Record<K, unknown>> {
    this.selectedFields.push(field);
    return this as unknown as QueryBuilder<T & Record<K, unknown>>;
  }

  where(condition: string): this {
    this.conditions.push(condition);
    return this;
  }

  build(): { fields: string[]; conditions: string[] } {
    return { fields: this.selectedFields, conditions: this.conditions };
  }
}

const query = new QueryBuilder()
  .select('id')
  .select('name')
  .where('active = true')
  .build();
```

---

## Common Generic Patterns

### MaybePromise

```typescript
type MaybePromise<T> = T | Promise<T>;

async function normalize<T>(value: MaybePromise<T>): Promise<T> {
  return await value;
}
```

### DeepPartial

```typescript
type DeepPartial<T> = T extends (infer U)[]
  ? DeepPartial<U>[]
  : T extends object
  ? { [K in keyof T]?: DeepPartial<T[K]> }
  : T;
```

### PathOf and Get

```typescript
// PathOf: all dot-notation paths into an object
type PathOf<T> = T extends object
  ? { [K in keyof T]: K extends string
      ? T[K] extends object
        ? K | `${K}.${PathOf<T[K]>}`
        : K
      : never
    }[keyof T]
  : never;

// Get: value at a path
type Get<T, P extends string> =
  P extends `${infer K}.${infer Rest}`
    ? K extends keyof T ? Get<T[K], Rest> : never
    : P extends keyof T ? T[P] : never;
```

### Prettify (Flatten Intersection Types for Readability)

```typescript
type Prettify<T> = { [K in keyof T]: T[K] } & {};

type A = { id: string } & { name: string } & { age: number };
type B = Prettify<A>; // { id: string; name: string; age: number }
// B displays as a single object in IDE hover, much more readable
```

### RequireAtLeastOne

```typescript
type RequireAtLeastOne<T, Keys extends keyof T = keyof T> =
  Omit<T, Keys> &
  { [K in Keys]-?: Required<Pick<T, K>> & Partial<Omit<T, K>> }[Keys];

interface ContactOptions {
  email?: string;
  phone?: string;
  address?: string;
}

type Contact = RequireAtLeastOne<ContactOptions>;
// Must provide at least one of email, phone, or address
```

### RequireExactlyOne

```typescript
type RequireExactlyOne<T, Keys extends keyof T = keyof T> =
  Omit<T, Keys> &
  { [K in Keys]: Required<Pick<T, K>> & { [O in Exclude<Keys, K>]?: never } }[Keys];

interface PaymentMethod {
  creditCard?: { number: string };
  bankTransfer?: { account: string };
  paypal?: { email: string };
}

type Payment = RequireExactlyOne<PaymentMethod>;
// Must provide exactly one payment method
```
