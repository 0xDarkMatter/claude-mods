# Language Version Upgrades

Detailed upgrade paths for major programming language version transitions. Verified
2026-10-22 against each language's release notes (cited in the newest sections).

One file on purpose: SKILL.md links it as the single language reference, and each
language section stands alone, so jump to the one you need instead of splitting the file.

## Contents

- [Python 3.9 to 3.15](#python-39-to-315)
- [Node.js 18 to 26](#nodejs-18-to-26)
- [TypeScript 4.x to 7.0](#typescript-4x-to-70)
- [Go 1.20 to 1.27](#go-120-to-127)
- [Rust Edition 2021 to 2024](#rust-edition-2021-to-2024)
- [PHP 8.1 to 8.5](#php-81-to-85)
- [Cross-Language Upgrade Checklist](#cross-language-upgrade-checklist)

---

## Python 3.9 to 3.15

### Python 3.10 (from 3.9)

**Key Features Gained:**
- Structural pattern matching (`match`/`case`)
- Parenthesized context managers
- Better error messages with precise line indicators
- `typing.TypeAlias` for explicit type aliases
- `zip()` gets `strict` parameter
- `bisect` and `statistics` module improvements

**Breaking Changes:**
- `distutils` deprecated (use `setuptools` instead)
- `loop` parameter removed from most `asyncio` high-level APIs
- `int` has a new `bit_count()` method (name collision risk)

**Migration Commands:**
```bash
# Update pyproject.toml / setup.cfg
python-requires = ">=3.10"

# Run pyupgrade for syntax modernization
pip install pyupgrade
pyupgrade --py310-plus $(fd -e py)

# Check for distutils usage
rg "from distutils" .
rg "import distutils" .
```

### Python 3.11 (from 3.10)

**Key Features Gained:**
- Exception groups and `except*` syntax
- `tomllib` in standard library (TOML parsing)
- Task groups in asyncio (`asyncio.TaskGroup`)
- Fine-grained error locations in tracebacks
- 10-60% faster CPython (Faster CPython project)
- `Self` type in `typing` module
- `StrEnum` class

**Breaking Changes:**
- `asyncio.coroutine` decorator removed
- `unittest.TestCase.addModuleCleanup` behavior change
- `locale.getdefaultlocale()` deprecated
- `smtpd` module removed (use `aiosmtpd`)

**Migration Commands:**
```bash
pyupgrade --py311-plus $(fd -e py)

# Replace manual TOML parsing
rg "import toml\b" .        # replace with: import tomllib
rg "toml\.loads?" .          # replace with: tomllib.loads / tomllib.load

# Check for removed modules
rg "import smtpd" .
rg "asyncio\.coroutine" .
```

### Python 3.12 (from 3.11)

**Key Features Gained:**
- Type parameter syntax (`class Stack[T]:`, `def first[T](l: list[T]) -> T:`)
- `type` statement for type aliases (`type Vector = list[float]`)
- F-string improvements (nested quotes, backslashes, comments)
- Per-interpreter GIL (subinterpreters)
- `pathlib.Path.walk()` method
- Improved `asyncio.TaskGroup` semantics
- Buffer protocol accessible from Python (`__buffer__`)

**Breaking Changes:**
- `distutils` package removed entirely (was deprecated in 3.10)
- `imp` module removed (use `importlib`)
- `locale.getdefaultlocale()` removed
- `unittest` method aliases removed (`assertEquals` etc.)
- `asyncio` legacy API removals
- `pkgutil.find_loader()` / `get_loader()` removed
- `sqlite3` default adapters and converters no longer registered by default
- `os.popen()` and `os.spawn*()` deprecated
- Wstr representation removed from C API

**Migration Commands:**
```bash
pyupgrade --py312-plus $(fd -e py)

# Check for removed modules
rg "import imp\b" .          # replace with importlib
rg "from imp " .
rg "import distutils" .      # must use setuptools
rg "from distutils" .

# Check for removed unittest aliases
rg "assertEquals|assertNotEquals|assertRegexpMatches" .

# Adopt new type syntax (optional but recommended)
# Old: T = TypeVar('T')
# New: def func[T](x: T) -> T:
```

### Python 3.13 (from 3.12)

**Key Features Gained:**
- Free-threaded mode (experimental, `--disable-gil` build)
- Improved interactive interpreter (REPL with colors, multiline editing)
- `locals()` returns copy with defined semantics
- Improved error messages (color, suggestions)
- `dbm.sqlite3` as default dbm backend
- `argparse` deprecations enforced
- JIT compiler (experimental, `--enable-experimental-jit` build)

**Breaking Changes:**
- `aifc`, `audioop`, `cgi`, `cgitb`, `chunk`, `crypt`, `imghdr`, `mailcap`, `msilib`, `nis`, `nntplib`, `ossaudiodev`, `pipes`, `sndhdr`, `spwd`, `sunau`, `telnetlib`, `uu`, `xdrlib` modules removed
- `pathlib.PurePath.is_relative_to()` and `relative_to()` semantics change
- `typing.io` and `typing.re` namespaces removed
- `locale.resetlocale()` removed
- C API changes affecting extension modules

**Migration Commands:**
```bash
# Check for removed stdlib modules
rg "import (aifc|audioop|cgi|cgitb|chunk|crypt|imghdr|mailcap|nis|nntplib|ossaudiodev|pipes|sndhdr|spwd|sunau|telnetlib|uu|xdrlib)" .

# For cgi module replacement
rg "import cgi" .       # replace with: from urllib.parse import parse_qs
rg "cgi.FieldStorage" . # replace with: manual multipart parsing or framework

# Check for typing namespace changes
rg "typing\.io\." .
rg "typing\.re\." .

# Test free-threaded mode (experimental)
python3.13t script.py  # if built with --disable-gil
```

### Python 3.14 (from 3.13)

**Key Features Gained:**
- Deferred evaluation of annotations by default (PEP 649/749) — inspect via `annotationlib`; `from __future__ import annotations` is no longer needed
- Template strings / t-strings (PEP 750)
- Free-threaded build officially supported (PEP 779 — still a separate build, no longer "experimental")
- Multiple interpreters in the stdlib (`concurrent.interpreters`, PEP 734)
- Zstandard compression (`compression.zstd`, PEP 784)
- Safe external debugger interface (`sys.remote_exec`)

**Breaking Changes:**
- `asyncio.get_event_loop()` no longer creates a new event loop — use `asyncio.run()` or `get_running_loop()`
- Long-deprecated `ast` aliases (`ast.Num`, `ast.Str`, `ast.Bytes`, ...) removed — use `ast.Constant`
- Annotation-introspection code that reads `__annotations__` eagerly may see deferred semantics — migrate to `annotationlib`

**Migration Commands:**
```bash
# Find eager-annotation assumptions
rg "from __future__ import annotations" .   # now redundant (harmless to keep)
rg "__annotations__" .                       # candidates for annotationlib

# Find event-loop creation via the removed pattern
rg "asyncio\.get_event_loop\(\)" .

# Modernize syntax to the new floor
pyupgrade --py314-plus **/*.py
```

### Python 3.15 (from 3.14)

Released 2026-10-09. Source: [What's New in Python 3.15](https://docs.python.org/3.15/whatsnew/3.15.html).

**Key Features Gained:**
- Explicit lazy imports (PEP 810): `lazy import json` / `lazy from pathlib import Path` defer loading until first use (`lazy` is a soft keyword)
- `frozendict` built-in (PEP 814): immutable, hashable when its contents are, not a `dict` subclass
- `sentinel` built-in (PEP 661) for unique sentinel values that survive copy and pickle
- Unpacking in comprehensions (PEP 798): `[*L for L in lists]`, `{**d for d in dicts}`
- Dedicated `profiling` package with the Tachyon sampling profiler (PEP 799)
- Stable ABI for free-threaded builds (PEP 803); macOS installers ship free-threading by default
- Frame pointers on by default (PEP 831); upgraded experimental JIT; typing: `TypedDict` extra items (PEP 728), `TypeForm` (PEP 747)

**Breaking Changes:**
- **UTF-8 is the default encoding (PEP 686).** `open()` and friends without `encoding=` now use UTF-8, not the locale encoding, which bites Windows code that relied on cp1252. Opt out with `PYTHONUTF8=0` or `-X utf8=0`
- `sqlite3.connect()` parameters other than `database` are keyword-only
- AST node constructors raise `TypeError` on missing or unknown fields (deprecated since 3.13)
- `datetime.strptime()` raises on `%d` without a year directive
- Removed: `sre_compile` / `sre_constants` / `sre_parse`, `http.server` `CGIHTTPRequestHandler` and `--cgi`, `importlib` `Loader.load_module()`, `platform.java_ver()`, `glob.glob0/glob1`, `pathlib.PurePath.is_reserved()`, `types.CodeType.co_lnotab`, keyword-argument `NamedTuple(...)` and field-less `TypedDict("TD")`
- `argparse`: in `add_argument('-f', '-foo')`, `dest` is now inferred from the single-dash long option (`foo`)
- `base64.urlsafe_b64decode()` no longer requires padding (pass `padded=True` to require it)
- `unittest` `assertWarns*()` no longer swallows non-matching warnings, so tests may leak previously hidden warnings

**Migration Commands:**
```bash
# Find text I/O that silently depended on the locale encoding
python -X warn_default_encoding -W error::EncodingWarning -m pytest
rg "open\([^)]*\)" --glob "*.py" | rg -v "encoding="

# Removed modules and APIs
rg "import sre_(compile|constants|parse)|CGIHTTPRequestHandler|\.load_module\(|java_ver\(|co_lnotab" .

# sqlite3 now keyword-only after the database argument
rg "sqlite3\.connect\([^)]*,[^=)]*\)" --glob "*.py"

pyupgrade --py315-plus **/*.py
```

### Python Version Upgrade Summary

| From → To | Key Action | Biggest Risk |
|-----------|-----------|--------------|
| 3.9 → 3.10 | Fix `distutils` usage, adopt pattern matching | `asyncio` loop parameter removal |
| 3.10 → 3.11 | Replace `toml` with `tomllib`, enjoy speed boost | `smtpd` removal |
| 3.11 → 3.12 | Remove `distutils`/`imp`, adopt type syntax | `distutils` full removal, sqlite3 adapter changes |
| 3.12 → 3.13 | Remove deprecated stdlib modules | Large number of removed stdlib modules |
| 3.13 → 3.14 | Adopt deferred annotations + t-strings | `asyncio.get_event_loop()` no longer creates a loop |
| 3.14 → 3.15 | Pass `encoding=` explicitly, adopt lazy imports | UTF-8 default encoding changes untagged file I/O |

---

## Node.js 18 to 26

### Node.js 20 (from 18)

**Key Features Gained:**
- Permission model (`--experimental-permission`)
- Stable test runner (`node:test`)
- `.env` file support (`--env-file=.env`)
- V8 11.3 (improved performance)
- `import.meta.resolve()` unflagged
- Single executable applications (SEA)
- `URL.canParse()` static method
- `ArrayBuffer.transfer()` and `resizable` option
- `WebSocket` client (experimental)

**Breaking Changes:**
- `url.parse()` may throw on invalid URLs (stricter parsing)
- `fs.read()` parameter validation stricter
- Custom ESM loader hooks (`load`, `resolve`) are off-thread
- `http.IncomingMessage` connected socket timeout default change

**Migration Commands:**
```bash
# Update nvm / fnm
nvm install 20
nvm use 20

# Or update Docker
# FROM node:20-alpine

# Check for url.parse usage (may need URL constructor)
rg "url\.parse\(" .

# Adopt built-in test runner (optional)
# Replace: jest/mocha test files
# With: import { test, describe } from 'node:test';

# Use .env file support
node --env-file=.env app.js
```

### Node.js 22 (from 20)

**Key Features Gained:**
- `require()` for ESM modules (experimental `--experimental-require-module`)
- WebSocket client stable
- Built-in watch mode stable (`node --watch`)
- `glob` and `globSync` in `node:fs`
- V8 12.4 (Maglev compiler, `Array.fromAsync`)
- `node:sqlite` built-in module (experimental)
- `--run` flag for package.json scripts
- Task runner integration
- `AbortSignal.any()`
- Stable permission model

**Breaking Changes:**
- `node:http` stricter header validation
- `node:buffer` Blob changes
- Minimum glibc 2.28 on Linux
- `node:child_process` IPC serialization changes
- `node:dns` default resolver changes

**Migration Commands:**
```bash
nvm install 22
nvm use 22

# Or update Docker
# FROM node:22-alpine

# Check for incompatible native modules
npm rebuild

# Test ESM/CJS interop if using mixed modules
node --experimental-require-module app.js

# Adopt built-in features
# Replace: glob package → node:fs { glob, globSync }
# Replace: ws package → built-in WebSocket (for client usage)
# Replace: chokidar/nodemon → node --watch
```

### Node.js 24 (from 22)

**Key Features Gained:**
- `require()` of ESM modules enabled by default (no flag)
- V8 13.6 — `Float16Array`, `RegExp.escape`, `Error.isError`, explicit resource management (`await using`)
- `URLPattern` as a global
- Permission model stable (flag renamed to `--permission`)
- npm 11, Undici 7

**Breaking Changes:**
- Windows native builds drop MSVC (ClangCL toolchain) — affects native-addon build pipelines
- Assorted deprecated API removals (`url.parse()` further discouraged — use `URL`)

**Migration Commands:**
```bash
nvm install 24
nvm use 24
# FROM node:24-alpine

npm rebuild                      # native modules against new ABI
rg "require\(['\"]\./.*\.mjs" .  # spots that relied on require(esm) flags
```

### Node.js 26 (from 24)

Node 26 was released 2026-05-05 as the Current line and is scheduled to enter Active LTS
on 2026-10-28 (endoflife.date). For production, upgrade LTS-to-LTS: 24 → 26 once 26 is
LTS. Node 25 reached end of life on 2026-06-01. The mechanics are
the same as every even-major bump: rebuild native modules, re-run the test suite on the
new V8, and update `FROM node:26` images plus CI matrices when you cut over.

### Node.js Version Upgrade Summary

| From → To | Key Action | Biggest Risk |
|-----------|-----------|--------------|
| 18 → 20 | Rebuild native modules, test URL parsing | Stricter URL validation, loader hooks off-thread |
| 20 → 22 | Rebuild native modules, check glibc version | Native module compatibility, header validation |
| 22 → 24 | Adopt require(esm), permission model | Native-addon toolchain change on Windows |
| 24 → 26 | LTS-to-LTS bump when 26 enters LTS (2026-10-28) | Riding the Current line before LTS |

---

## TypeScript 4.x to 7.0

### TypeScript 5.0 (from 4.9)

**Key Features Gained:**
- ECMAScript decorators (stage 3 standard)
- `const` type parameters
- `--moduleResolution bundler`
- `extends` on multiple config files
- All `enum`s become union `enum`s
- `--verbatimModuleSyntax` (replaces `isolatedModules`)
- Speed and size improvements (TS migrated to modules internally)
- `satisfies` operator (introduced in 4.9, now mature)

**Breaking Changes:**
- `--target ES3` removed
- `--out` removed (use `--outFile`)
- `--noImplicitUseStrict` removed
- `--suppressExcessPropertyErrors` removed
- `--suppressImplicitAnyIndexErrors` removed
- `--prepend` in project references removed
- Runtime behavior of decorators changed (now ECMAScript standard)
- `--moduleResolution node` renamed to `node10`
- `--module` value changes

**Migration Commands:**
```bash
npm install -D typescript@5

# Check for removed compiler options in tsconfig.json
rg '"target":\s*"ES3"' tsconfig.json
rg '"out":' tsconfig.json
rg '"suppressExcessPropertyErrors"' tsconfig.json

# If using legacy decorators, keep experimentalDecorators flag
# If adopting new decorators, remove experimentalDecorators

# Adopt bundler module resolution
# tsconfig.json: "moduleResolution": "bundler"
```

### TypeScript 5.1-5.7 Highlights

| Version | Key Feature |
|---------|-------------|
| **5.1** | Easier implicit return for `undefined`, unrelated getter/setter types |
| **5.2** | `using` declarations (explicit resource management), decorator metadata |
| **5.3** | `import` attribute support, `resolution-mode` in all module modes |
| **5.4** | `NoInfer<T>` utility type, `Object.groupBy` / `Map.groupBy` types |
| **5.5** | Inferred type predicates, regex syntax checking, `isolatedDeclarations` |
| **5.6** | Iterator helper methods, `--noUncheckedSideEffectImports` |
| **5.7** | `--rewriteRelativeImportExtensions`, `--target es2024` |

### TypeScript 6.0 (from 5.x)

The last release on the JavaScript-based compiler — 6.0 modernises defaults as the
bridge to the native (Go) compiler in TypeScript 7.

**Key Features Gained:**
- `es2025` target/lib with types for Temporal, `Map.getOrInsert`, `RegExp.escape`
- Better inference for `this`-less functions; `#/` subpath-import support
- `--stableTypeOrdering` flag to ease 6.0 → 7.0 migration diffing
- Large-monorepo `tsc --watch` rebuilds significantly faster

**Breaking Changes:**
- `strict: true` is now the **default**, so configs that never set it surface new errors
- Defaults changed: `module: esnext`, `target` = the newest stable ES version (es2025),
  `noUncheckedSideEffectImports: true`, `rootDir: ./`, `types: []`. The last two
  surprise most projects: list your `@types` packages explicitly and set `rootDir`
- Deprecated, an error unless silenced with `"ignoreDeprecations": "6.0"`, and a **hard
  error in 7.0**: `target: es5`, `downlevelIteration`, `moduleResolution: node`/`node10`/`classic`,
  `module: amd/umd/system/none`, `baseUrl`, `esModuleInterop` / `allowSyntheticDefaultImports: false`,
  `alwaysStrict: false`, `import ... asserts {}` (use `with`)
- Namespace-with-class merging requires explicit `export`

**Migration Commands:**
```bash
npm install -D typescript@6

# Find options 6.0 removed or hard-wires
rg '"moduleResolution":\s*"classic"' tsconfig.json
rg '"module":\s*"(amd|umd|system|none)"' tsconfig.json
rg '"esModuleInterop":\s*false' tsconfig.json
rg '"target":\s*"es5"' -i tsconfig.json

# Surface the strict-by-default delta before committing to it
npx tsc --noEmit
```

### TypeScript 7.0 (from 6.0)

Released 2026-07-08 (7.0.2 on 2026-08-20; 7.1 beta on 2026-10-20). Sources:
[Announcing TypeScript 7.0](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/),
[typescript-go CHANGES.md](https://github.com/microsoft/typescript-go/blob/main/CHANGES.md).

7.0 is the **native port** of the compiler and language service, written in Go. It
typically builds 8-12x faster, uses shared-memory multithreading, and speaks LSP. It is
built to type-check exactly like 6.0: code that compiles cleanly on 6.0 with
`stableTypeOrdering` on and no `ignoreDeprecations` should compile identically on 7.0.

**Key Features Gained:**
- 8-12x faster full builds, faster `--watch`, and parallel type-checking and project-reference builds (`--singleThreaded` to opt out)
- New LSP-based language server (VS Code: the dedicated TypeScript 7 extension; Visual Studio enables it per workspace)
- Template-literal inference treats Unicode code points as one unit (`"😀abc"` → `["😀", "abc"]`)

**Breaking Changes:**
- **No programmatic compiler API in 7.0** (a new, different API is expected in 7.1). Tools that import `typescript` (typescript-eslint, Volar-based Vue/MDX/Astro/Svelte tooling, Angular template checking) must keep running on 6.0
- Every 6.0 deprecation is a hard error (`target: es5`, `downlevelIteration`, `moduleResolution: node10`/`classic`, `module: amd/umd/system/none`, `baseUrl`, `esModuleInterop: false`, `alwaysStrict: false`, `asserts` import attributes, `module` keyword for namespaces)
- `stableTypeOrdering` is always on and cannot be turned off
- `tsc file.ts` in a directory that has a `tsconfig.json` errors unless you pass `--ignoreConfig`
- JS/JSDoc checking was reworked to match `.ts` analysis: no values as types (use `typeof`), no special `@enum` or `@class`, no Closure function-type syntax, no standalone `?` type
- Type-level string utilities that modeled UTF-16 code units change results

**Migration Commands:**
```bash
# Step 1: be clean on 6.0 first, with no ignoreDeprecations and stableTypeOrdering on
rg '"ignoreDeprecations"' --glob "tsconfig*.json"
npx tsc --noEmit --stableTypeOrdering

# Step 2: install 7.0
npm install -D typescript@7

# Tools that need the compiler API: keep 6.0 under the `typescript` name (tsc6 binary),
# alias 7.0 so `npx tsc` is the native compiler
npm install -D typescript@npm:@typescript/typescript6@^6.0.2 @typescript/native@npm:typescript@^7.0.2

# Nightlies now publish as typescript@next (was @typescript/native-preview)
```

### Migration Strategy

```
TypeScript version upgrade approach:
│
├─ Minor version (x.y → x.z)
│  └─ Generally safe, just update and fix new errors
│     npm install -D typescript@latest
│     npx tsc --noEmit
│
├─ Major version (4.x → 5.x)
│  ├─ 1. Update tsconfig.json (remove deleted options)
│  ├─ 2. Install typescript@5
│  ├─ 3. Run tsc --noEmit, fix errors
│  ├─ 4. Decide on decorator strategy (legacy vs ECMAScript)
│  └─ 5. Consider adopting moduleResolution: "bundler"
│
├─ Major version (5.x → 6.0)
│  ├─ 1. Set strict: true explicitly and fix errors BEFORE upgrading
│  ├─ 2. Replace deprecated module/moduleResolution/baseUrl options
│  ├─ 3. Set rootDir and types explicitly (new defaults: ./ and [])
│  ├─ 4. Install typescript@6, run tsc --noEmit
│  └─ 5. Pin the target you actually ship (defaults moved to es2025)
│
└─ Major version (6.0 → 7.0)
   ├─ 1. Remove ignoreDeprecations; build clean with --stableTypeOrdering on 6.0
   ├─ 2. Inventory tools that import the compiler API (eslint, Vue/Svelte/Astro, Angular)
   ├─ 3. Install typescript@7; keep @typescript/typescript6 for those tools
   └─ 4. Switch editors to the TypeScript 7 language server; keep 6.0 for embedded-language projects
```

---

## Go 1.20 to 1.27

### Go 1.21 (from 1.20)

**Key Features Gained:**
- `log/slog` structured logging (standard library)
- `slices` and `maps` packages in standard library
- `min()` and `max()` built-in functions
- `clear()` built-in for maps and slices
- PGO (Profile-Guided Optimization) generally available
- `go.mod` toolchain directive
- Forward compatibility (`GOTOOLCHAIN` environment variable)

**Breaking Changes:**
- `go.mod` now tracks toolchain version
- Panic on `nil` pointer dereference in more cases
- `net/http` minor behavior changes

**Migration Commands:**
```bash
# Update go.mod
go mod edit -go=1.21
go mod tidy

# Adopt slog for structured logging
rg "log\.Printf|log\.Println" .  # candidates for slog migration

# Replace sort.Slice with slices.SortFunc
rg "sort\.Slice\b" .  # consider slices.SortFunc
```

### Go 1.22 (from 1.21)

**Key Features Gained:**
- `for range` over integers (`for i := range 10`)
- Enhanced `net/http` routing (method + path patterns)
- Loop variable fix (each iteration gets its own variable)
- `math/rand/v2` package
- `go/version` package
- `slices.Concat`

**Breaking Changes:**
- Loop variable semantics change (each iteration gets a copy -- fixes the classic goroutine-in-loop bug)
- `math/rand` global functions deterministic without seed

**Migration Commands:**
```bash
go mod edit -go=1.22
go mod tidy

# The loop variable change is backward compatible but may fix hidden bugs
# Review goroutine closures in loops that relied on shared variable

# Adopt enhanced routing
# Old: mux.HandleFunc("/users", handler) + manual method check
# New: mux.HandleFunc("GET /users/{id}", handler)
rg "r\.Method ==" .  # candidates for enhanced routing
```

### Go 1.23 (from 1.22)

**Key Features Gained:**
- Iterators (`iter.Seq`, `iter.Seq2`) and `range over func`
- `unique` package (interning/canonicalization)
- `structs` package (struct layout control)
- Timer/Ticker changes (garbage collected when unreferenced)
- `slices` and `maps` moved from `golang.org/x/exp` to standard library
- OpenTelemetry-compatible `log/slog` handlers

**Breaking Changes:**
- `time.Timer` and `time.Ticker` behavior change (channels drained on Stop/Reset)
- `os/exec` `LookPath` behavior on Windows (security fix)

**Migration Commands:**
```bash
go mod edit -go=1.23
go mod tidy

# Replace x/exp/slices and x/exp/maps with standard library versions
rg "golang.org/x/exp/slices" .
rg "golang.org/x/exp/maps" .
# Replace with: "slices" and "maps"

# Check Timer/Ticker usage
rg "\.Stop\(\)" . --glob "*.go"  # Review timer stop behavior
rg "\.Reset\(" . --glob "*.go"   # Review timer reset behavior
```

### Go 1.24 – 1.25 (from 1.23)

**Key Features Gained:**
- **1.24**: generic type aliases; `tool` directives in go.mod (tracked tool deps); `os.Root` (filesystem-scoped file access); Swiss-table map implementation (runtime perf); `weak` package; `runtime.AddCleanup` (successor to `SetFinalizer`)
- **1.25**: container-aware `GOMAXPROCS` (respects cgroup CPU limits); `testing/synctest` for concurrent-code tests; experimental green-tea GC

**Breaking Changes:**
- Effectively none at the language level (Go 1 compatibility promise); behavior deltas are gated on the `go` directive version in go.mod, so bumps activate deliberately

### Go 1.26 (from 1.25)

Released 2026-02-10. Source: [Go 1.26 Release Notes](https://go.dev/doc/go1.26).

**Key Features Gained:**
- `new(expr)`: the built-in `new` takes an initial value (`Age: new(yearsSince(born))`), handy for pointer-to-optional fields
- Generic types may refer to themselves in their own type-parameter constraints (`type Adder[A Adder[A]] interface{...}`)
- Green Tea garbage collector **on by default** (10-40% less GC overhead in GC-heavy programs)
- `go fix` rebuilt as the home of **modernizers** on the `go vet` analysis framework, plus `//go:fix inline` for automated API migrations; the old obsolete fixers are gone
- Faster cgo calls; heap base address randomization; `crypto/hpke`; experimental `simd/archsimd` and `runtime/secret`; goroutine-leak profile as an experiment

**Breaking Changes:**
- `go mod init` writes the previous Go version (`go 1.25.0` from a 1.26 toolchain)
- `cmd/doc` and `go tool doc` were deleted (use `go doc`)
- Last release supporting macOS 12

### Go 1.27 (from 1.26)

Released 2026-08-19. Source: [Go 1.27 Release Notes](https://go.dev/doc/go1.27).

**Key Features Gained:**
- **Generic methods**: a method may declare its own type parameters (`func (r *Rand) N[Int intType](n Int) Int`). Interface methods still cannot, and generic methods do not implement interface methods
- Struct-literal keys may be any field selector, not just a top-level field name; function type inference works wherever a generic function is assigned to a matching function type
- `encoding/json/v2` and `encoding/json/jsontext` are GA. `encoding/json` itself is now **backed by the v2 implementation** (same behaviour, faster unmarshal, different error text)
- New `uuid` and `crypto/mldsa` (post-quantum ML-DSA, also in `crypto/x509` and TLS 1.3) packages; experimental `simd`
- `goroutineleak` profile GA (`runtime/pprof`, `/debug/pprof/goroutineleak`); size-specialized small allocations (up to 30% cheaper, about 60 KB more binary)
- `go doc pkg@version`, `go doc -ex`; new `go fix` modernizers; `go mod tidy` merges duplicate require blocks for `go 1.27` modules

**Breaking Changes:**
- **macOS 13 Ventura or later required**
- `asynctimerchan` GODEBUG removed: `time` channels are always unbuffered. A `go.mod` or `//go:debug` line setting it to the old value now **fails the build**
- `go test` runs the `stdversion` vet check by default (flags stdlib symbols newer than the file's Go version)
- `gofmt` alignment fix: reformatting previously formatted code can produce small whitespace diffs, so expect churn in a repo-wide `gofmt -l` check
- `encoding/json` error messages differ. Tests asserting on exact error text break; `GOEXPERIMENT=nojsonv2` restores v1 temporarily
- `go fix`: `waitgroup` renamed `waitgroupgo`, `fmtappendf` removed; `bzr` VCS support dropped; `go tool trace -http=:port` binds localhost only
- Closure (function literal) symbol names changed, which affects tests that match on symbol names

**Migration Commands:**
```bash
go mod edit -go=1.27
go mod tidy
go vet ./...
go test ./...            # now includes the stdversion vet check
govulncheck ./...

# GODEBUG settings that 1.27 removed: an old value fails the build
rg "asynctimerchan" --glob "go.mod" --glob "*.go"

# Tests that pin encoding/json error strings
rg 'json: (cannot|invalid|unexpected)' --glob "*_test.go"

# Modernize with the 1.26+ go fix
go fix ./...

# Adopt tool directives (1.24+) - replaces the tools.go pattern
go get -tool golang.org/x/tools/cmd/stringer
```

### Go Version Upgrade Summary

| From → To | Key Action | Biggest Risk |
|-----------|-----------|--------------|
| 1.20 → 1.21 | Update go.mod toolchain, adopt slog | Toolchain directive in go.mod |
| 1.21 → 1.22 | Enjoy loop variable fix, adopt enhanced routing | Loop variable semantics (usually fixes bugs) |
| 1.22 → 1.23 | Replace x/exp packages, adopt iterators | Timer/Ticker behavior change |
| 1.23 → 1.25 | Bump go directive stepwise, adopt tool directives + os.Root | Runtime perf deltas (Swiss maps, GC) in hot paths |
| 1.25 → 1.26 | Run the new `go fix` modernizers, adopt `new(expr)` | Green Tea GC now default (measure GC-heavy services) |
| 1.26 → 1.27 | Adopt generic methods, `encoding/json/v2` where useful | Removed `asynctimerchan`, json error text, macOS 13 floor |

---

## Rust Edition 2021 to 2024

### Key Features in Edition 2024

- **RPITIT** (Return Position Impl Trait in Traits): use `-> impl Trait` in trait definitions
- **Async fn in traits**: `async fn` directly in trait definitions (no need for `async-trait` crate)
- **`let` chains**: `if let Some(x) = a && let Some(y) = b { ... }`
- **`gen` blocks** (experimental): generator-based iterators
- **Lifetime capture rules**: all in-scope lifetimes captured by default in `-> impl Trait`
- **`unsafe_op_in_unsafe_fn`** lint: must use `unsafe {}` blocks inside `unsafe fn`
- **Precise capturing** with `use<>` syntax
- **`#[diagnostic]` attribute** namespace for custom diagnostics
- **Reserving `gen` keyword** for generators
- **Temporary lifetime extension** changes in `match` and `if let`

### Breaking Changes

| Change | Impact | Fix |
|--------|--------|-----|
| `unsafe_op_in_unsafe_fn` is deny by default | `unsafe fn` bodies need explicit `unsafe {}` blocks | Wrap unsafe operations in `unsafe {}` |
| Lifetime capture rules change | `-> impl Trait` captures all in-scope lifetimes | Use `use<'a>` for precise control |
| `gen` is a reserved keyword | Cannot use `gen` as identifier | Rename `gen` variables/functions |
| `never` type fallback changes | `!` type fallback now `!` instead of `()` | May affect type inference in rare cases |
| Temporary lifetime changes | Temporaries in `match` scrutinee have shorter lifetime | Store temporaries in `let` bindings |
| `unsafe extern` blocks | `extern` items implicitly unsafe to reference | Add `safe` keyword to safe extern items |
| Disallow references to `static mut` | `&STATIC_MUT` is forbidden | Use `addr_of!()` / `addr_of_mut!()` |

### Migration Commands

```bash
# Automatic edition migration
cargo fix --edition

# Update Cargo.toml
# edition = "2024"

# Fix unsafe_op_in_unsafe_fn warnings
cargo clippy --fix -- -W unsafe_op_in_unsafe_fn

# Check for gen keyword conflicts
rg "\bgen\b" src/ --glob "*.rs"

# Remove async-trait crate if adopting native async traits
rg "async.trait" Cargo.toml
rg "#\[async_trait\]" src/
```

### Verification Steps

```bash
cargo build
cargo test
cargo clippy -- -D warnings
cargo doc --no-deps  # check documentation builds
```

---

## PHP 8.1 to 8.5

### PHP 8.2 (from 8.1)

**Key Features Gained:**
- Readonly classes
- Disjunctive Normal Form (DNF) types
- `null`, `false`, `true` as standalone types
- Constants in traits
- Enum improvements
- Random extension (`\Random\Randomizer`)
- `SensitiveParameter` attribute
- Fibers improvements

**Breaking Changes:**
- Dynamic properties deprecated (use `#[AllowDynamicProperties]` or `__get`/`__set`)
- Implicit nullable parameter declarations deprecated
- `${var}` string interpolation deprecated (use `{$var}`)
- `utf8_encode` / `utf8_decode` deprecated
- Various internal class changes

**Migration Commands:**
```bash
# Rector automated fixes
composer require rector/rector --dev
vendor/bin/rector process src --set php82

# Check for dynamic properties
rg "->(\w+)\s*=" src/ --glob "*.php"  # review for undeclared properties

# Check deprecated string interpolation
rg '"\$\{' src/ --glob "*.php"
```

### PHP 8.3 (from 8.2)

**Key Features Gained:**
- Typed class constants
- `json_validate()` function
- `#[\Override]` attribute
- Deep cloning of readonly properties in `__clone()`
- Dynamic class constant fetch (`$class::{$constant}`)
- `Randomizer::getBytesFromString()`
- `mb_str_pad()` function
- Improved `unserialize()` error handling

**Breaking Changes:**
- `array_sum()` and `array_product()` behavior changes
- `proc_get_status()` multiple calls return same result
- `range()` type checking stricter
- `number_format()` behavior change with negative zero

**Migration Commands:**
```bash
vendor/bin/rector process src --set php83

# Adopt #[Override] attribute on methods
# This catches parent method renames at compile time

# Adopt typed constants
# Old: const STATUS = 'active';
# New: const string STATUS = 'active';

# Use json_validate() instead of json_decode() for validation
rg "json_decode.*json_last_error" src/ --glob "*.php"
```

### PHP 8.4 (from 8.3)

**Key Features Gained:**
- Property hooks (get/set)
- Asymmetric visibility (`public private(set)`)
- `#[\Deprecated]` attribute
- `new` without parentheses in chained expressions
- HTML5 DOM parser (`\Dom\HTMLDocument`)
- Lazy objects (`ReflectionClass::newLazyProxy()`)
- `array_find()`, `array_find_key()`, `array_any()`, `array_all()`
- `Multibyte` functions for `trim`, `ltrim`, `rtrim`
- `request_parse_body()` for non-POST requests

**Breaking Changes:**
- Implicitly nullable parameter types trigger deprecation notice
- `E_STRICT` constant deprecated
- `session_set_save_handler()` with `open`/`close` etc. deprecated
- `strtolower()` and `strtoupper()` locale-insensitive
- Various DOM API changes for HTML5 compliance

**Migration Commands:**
```bash
vendor/bin/rector process src --set php84

# Adopt property hooks (optional but recommended)
# Old:
# private string $name;
# public function getName(): string { return $this->name; }
# public function setName(string $name): void { $this->name = $name; }
# New:
# public string $name {
#     get => $this->name;
#     set(string $value) => $this->name = strtolower($value);
# }

# Adopt asymmetric visibility
# public private(set) string $name;

# Check for implicit nullable types
rg "function \w+\([^)]*\w+ \$\w+ = null" src/ --glob "*.php"
```

### PHP 8.5 (from 8.4)

**Key Features Gained:**
- Pipe operator `|>` for left-to-right call chaining
- `array_first()` and `array_last()`
- `#[\NoDiscard]` attribute (warn when a return value is ignored)
- Fatal errors now include backtraces
- `clone with` — update readonly/other properties during clone

**Breaking Changes:**
- Minor-release discipline: mostly new deprecations rather than removals; run the suite with deprecations surfaced (`error_reporting(E_ALL)`) before and after

**Migration Commands:**
```bash
vendor/bin/rector process src --set php85

# Adopt the pipe operator where nested calls hurt readability
# Old: trim(strtolower($name))
# New: $name |> strtolower(...) |> trim(...)

# Replace reset()/end() misuse for first/last element
rg "\breset\(|\bend\(" src/ --glob "*.php"   # candidates for array_first/array_last
```

### PHP Version Upgrade Summary

| From → To | Key Action | Biggest Risk |
|-----------|-----------|--------------|
| 8.1 → 8.2 | Fix dynamic properties, deprecation warnings | Dynamic properties deprecated |
| 8.2 → 8.3 | Adopt typed constants, #[Override] | array_sum/array_product behavior |
| 8.3 → 8.4 | Adopt property hooks, asymmetric visibility | Implicit nullable deprecation |
| 8.4 → 8.5 | Adopt pipe operator, array_first/array_last | New deprecations surfacing in dependencies |

---

## Cross-Language Upgrade Checklist

Regardless of which language you are upgrading:

```
[ ] CI matrix includes both old and new versions during transition
[ ] Linter/formatter updated to support new syntax
[ ] IDE / editor language server updated
[ ] Docker base images updated
[ ] Deployment pipeline runtime version updated
[ ] New language features documented in team style guide
[ ] Deprecated API usage eliminated before upgrade
[ ] All tests pass on new version
[ ] Performance benchmarks compared pre/post upgrade
[ ] Third-party dependencies verified compatible
```
