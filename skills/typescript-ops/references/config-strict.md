# TypeScript Configuration and Strict Mode Reference

## Table of Contents

1. [Strict Mode Flags](#strict-mode-flags)
2. [Migration Strategy](#migration-strategy)
3. [Module Configuration](#module-configuration)
4. [Path Aliases](#path-aliases)
5. [Project References](#project-references)
6. [Monorepo Setup](#monorepo-setup)
7. [Declaration Files](#declaration-files)

---

## Strict Mode Flags

### Enable the Full Strict Suite

`"strict": true` is shorthand for enabling all individual strict flags at once. Always enable it.

```json
{
  "compilerOptions": {
    "strict": true,

    // Additional strictness beyond "strict": true
    "noUncheckedIndexedAccess": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "exactOptionalPropertyTypes": true,
    "noPropertyAccessFromIndexSignature": true,
    "noImplicitOverride": true
  }
}
```

### Understand Each Flag

**strictNullChecks** - `null` and `undefined` are not assignable to other types. The most impactful flag.

```typescript
// Without strictNullChecks: null assignable to anything
// With strictNullChecks:
function getLength(s: string): number {
  return s.length; // OK
}
getLength(null); // Error: Argument of type 'null' is not assignable to parameter of type 'string'

// Forces explicit null handling:
function getName(user: { name: string } | null): string {
  return user?.name ?? 'Anonymous';
}
```

**strictFunctionTypes** - Function parameters are checked contravariantly, not bivariantly.

```typescript
type Animal = { name: string };
type Dog = Animal & { breed: string };

type AnimalCallback = (a: Animal) => void;
type DogCallback    = (d: Dog) => void;

let animalCb: AnimalCallback = (a) => console.log(a.name);
let dogCb: DogCallback = (d) => console.log(d.breed);

// With strictFunctionTypes, this is an error (unsafe in callback position):
// dogCb = animalCb; // DogCallback expects d.breed but AnimalCallback only provides a.name
```

**strictBindCallApply** - `.bind()`, `.call()`, `.apply()` are type-checked.

```typescript
function add(a: number, b: number): number { return a + b; }

add.call(null, 1, 2);   // OK
add.call(null, '1', 2); // Error: Argument of type 'string' not assignable to 'number'
add.bind(null, 1)(2);   // OK, typed as () => number after bind
```

**strictPropertyInitialization** - Class properties must be assigned in the constructor.

```typescript
class Service {
  name: string;       // Error: not definitely assigned
  id: string;         // Error: not definitely assigned

  // Fix options:
  optA: string = '';                              // default value
  optB!: string;                                  // definite assignment assertion (use sparingly)
  optC: string | undefined;                       // allow undefined
  constructor() { this.optA = this.optA; }       // assign in constructor
}
```

**noImplicitAny** - Variables whose type cannot be inferred default to `any` - this flag makes that an error.

```typescript
function process(data) { // Error: 'data' implicitly has an 'any' type
  return data.value;
}

function process(data: { value: string }): string { // OK
  return data.value;
}
```

**noImplicitThis** - `this` usage without explicit annotation is an error.

```typescript
function greet() {
  return this.name; // Error: 'this' implicitly has type 'any'
}

function greet(this: { name: string }): string {
  return this.name; // OK - this is typed
}
```

**useUnknownInCatchVariables** (part of strict in TS 4.4+) - Catch clause variables are `unknown`, not `any`.

```typescript
try {
  riskyOperation();
} catch (err) {
  // err is 'unknown' - must narrow before use
  if (err instanceof Error) {
    console.error(err.message); // OK
  } else {
    console.error(String(err)); // handle non-Error throws
  }
}
```

**noUncheckedIndexedAccess** - Index signatures include `undefined` in return type.

```typescript
const map: Record<string, string> = {};
const value = map['key']; // string | undefined (not just string)

// Forces null checking:
if (value !== undefined) {
  console.log(value.toUpperCase()); // OK
}
```

**exactOptionalPropertyTypes** - Distinguishes between `prop?: T` (absent or T) and `prop: T | undefined`.

```typescript
interface A { name?: string; }

// With exactOptionalPropertyTypes:
const a: A = { name: undefined }; // Error: undefined is not the same as absent
const b: A = {};                   // OK - name is absent
const c: A = { name: 'Alice' };    // OK
```

---

## Migration Strategy

### Adopt Strict Mode Incrementally

```json
// Phase 1: Start here - catches the worst issues
{
  "compilerOptions": {
    "noImplicitAny": true,
    "strictNullChecks": true
  }
}

// Phase 2: Add remaining strict flags
{
  "compilerOptions": {
    "strict": true
  }
}

// Phase 3: Tighten further
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noImplicitReturns": true
  }
}
```

### Use @ts-expect-error for Tracked Suppressions

Prefer `@ts-expect-error` over `@ts-ignore`. The former causes a type error if the suppressed line no longer has an error, making it self-cleaning.

```typescript
// @ts-ignore - silently does nothing if the error is later fixed (dead suppression)
const x: string = 42;

// @ts-expect-error - causes a type error when the suppressed error is fixed
// @ts-expect-error: temporary until API is updated
const y: string = legacyApi.getValue();
```

### Migration Checklist

```
[ ] Enable noImplicitAny first - forces all untyped code to be explicit
[ ] Add @ts-expect-error to suppress errors in files not yet migrated
[ ] Enable strictNullChecks - fix null/undefined handling
[ ] Enable strict: true - address remaining flags
[ ] Track suppressions with: grep -r "@ts-expect-error" . --include="*.ts"
[ ] Eliminate suppressions file by file
[ ] Enable noUncheckedIndexedAccess as final step (highest refactor cost)
```

---

## Module Configuration

### Choose the Right module and moduleResolution

```json
// For Node.js with CommonJS
{
  "compilerOptions": {
    "module": "CommonJS",
    "moduleResolution": "Node"
  }
}

// For Node.js with ESM (Node 18+) - recommended for new Node projects
{
  "compilerOptions": {
    "module": "Node16",       // or "NodeNext"
    "moduleResolution": "Node16"
  }
}

// For bundlers (Vite, webpack, esbuild, Rollup)
{
  "compilerOptions": {
    "module": "ESNext",
    "moduleResolution": "Bundler"
  }
}

// For browser projects with no bundler (rare)
{
  "compilerOptions": {
    "module": "ESNext",
    "moduleResolution": "Classic"  // avoid - use Bundler or Node16
  }
}
```

### Understand ESM vs CJS Interop Issues

With `Node16`/`NodeNext`, you must use explicit `.js` extensions in relative imports (even for `.ts` files).

```typescript
// tsconfig.json: "module": "Node16"

// WRONG - no extension
import { helper } from './helper';

// CORRECT - use .js extension (TypeScript resolves it to .ts)
import { helper } from './helper.js';
```

Set `"type": "module"` in `package.json` to use ESM, or use `.mts`/`.cts` file extensions to override per-file.

```json
// package.json
{
  "type": "module"
}
```

---

## Path Aliases

### Configure Paths in tsconfig.json

```json
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@/*":         ["./src/*"],
      "@components/*": ["./src/components/*"],
      "@utils/*":    ["./src/utils/*"],
      "@types/*":    ["./src/types/*"]
    }
  }
}
```

### Use Paths with Vite

```typescript
// vite.config.ts
import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  resolve: {
    alias: {
      '@': resolve(__dirname, './src'),
      '@components': resolve(__dirname, './src/components'),
      '@utils': resolve(__dirname, './src/utils'),
    },
  },
});
```

### Use Paths with Node (tsx / tsconfig-paths)

```bash
# Option 1: tsx (recommended for scripts/CLIs)
npx tsx --tsconfig tsconfig.json src/index.ts

# Option 2: tsconfig-paths with ts-node
npx ts-node -r tsconfig-paths/register src/index.ts

# Option 3: tsconfig-paths at runtime (after compilation)
node -r tsconfig-paths/register dist/index.js
```

```typescript
// tsconfig-paths at runtime setup
// bootstrap.js
const { register } = require('tsconfig-paths');
const tsConfig = require('./tsconfig.json');
register({
  baseUrl: tsConfig.compilerOptions.baseUrl,
  paths: tsConfig.compilerOptions.paths,
});
require('./dist/index.js');
```

---

## Project References

### Set Up Composite Projects

Project references allow incremental builds and better IDE performance in large repos.

```json
// packages/shared/tsconfig.json
{
  "compilerOptions": {
    "composite": true,    // required for project references
    "declaration": true,  // required for project references
    "declarationMap": true,
    "outDir": "./dist",
    "rootDir": "./src"
  }
}

// packages/app/tsconfig.json
{
  "compilerOptions": {
    "outDir": "./dist",
    "rootDir": "./src"
  },
  "references": [
    { "path": "../shared" }
  ]
}
```

### Build with --build Mode

```bash
# Build all referenced projects in dependency order
tsc --build

# Build and watch
tsc --build --watch

# Clean built outputs
tsc --build --clean

# Force rebuild
tsc --build --force
```

---

## Monorepo Setup

### Define a Root tsconfig for Shared Settings

```json
// tsconfig.base.json (root)
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitReturns": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true
  }
}

// packages/server/tsconfig.json
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "module": "CommonJS",
    "moduleResolution": "Node",
    "target": "ES2022",
    "outDir": "./dist",
    "rootDir": "./src"
  },
  "include": ["src/**/*"],
  "references": [{ "path": "../shared" }]
}

// packages/web/tsconfig.json
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "target": "ES2022",
    "jsx": "react-jsx",
    "outDir": "./dist",
    "rootDir": "./src"
  },
  "include": ["src/**/*"],
  "references": [{ "path": "../shared" }]
}
```

### Use a Root tsconfig for IDE Support

```json
// tsconfig.json (root - IDE only, not for building)
{
  "files": [],
  "references": [
    { "path": "./packages/shared" },
    { "path": "./packages/server" },
    { "path": "./packages/web" }
  ]
}
```

---

## Declaration Files

### Write Ambient Declarations for Untyped Modules

```typescript
// types/untyped-module.d.ts
declare module 'some-legacy-package' {
  export interface Options {
    timeout?: number;
    retries?: number;
  }

  export function connect(url: string, options?: Options): Promise<void>;
  export function disconnect(): void;

  export default {
    connect,
    disconnect,
  };
}

// Wildcard module for assets (e.g., CSS, SVG)
declare module '*.svg' {
  const content: string;
  export default content;
}

declare module '*.png' {
  const content: string;
  export default content;
}

declare module '*.css' {
  const styles: Record<string, string>;
  export default styles;
}
```

### Augment Global Scope

```typescript
// global.d.ts
declare global {
  // Extend the Window interface
  interface Window {
    __APP_VERSION__: string;
    analytics: {
      track(event: string, props?: Record<string, unknown>): void;
    };
  }

  // Extend ProcessEnv for typed environment variables
  namespace NodeJS {
    interface ProcessEnv {
      NODE_ENV: 'development' | 'production' | 'test';
      DATABASE_URL: string;
      API_KEY: string;
      PORT?: string;
    }
  }
}

export {}; // This export makes the file a module, enabling declare global
```

### Use Triple-Slash Directives

```typescript
// Reference a type definition file
/// <reference types="node" />
/// <reference types="jest" />

// Reference a specific .d.ts file
/// <reference path="../types/custom.d.ts" />

// Reference a lib
/// <reference lib="dom" />
/// <reference lib="es2022" />
```

### Write a .d.ts for a Hand-Authored JavaScript Library

```typescript
// src/math-helpers.js (source)
function add(a, b) { return a + b; }
function multiply(a, b) { return a * b; }
module.exports = { add, multiply };

// src/math-helpers.d.ts (declaration)
export declare function add(a: number, b: number): number;
export declare function multiply(a: number, b: number): number;
```

### Configure Declaration Output

```json
{
  "compilerOptions": {
    "declaration": true,         // emit .d.ts files
    "declarationDir": "./types", // output directory for .d.ts (optional)
    "declarationMap": true,      // emit .d.ts.map for source navigation
    "emitDeclarationOnly": true  // only emit .d.ts, no JS (when bundler handles JS)
  }
}
```
