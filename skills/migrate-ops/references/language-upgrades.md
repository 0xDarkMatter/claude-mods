# Language Version Upgrades

Detailed upgrade paths for major programming language version transitions.

---

## Python 3.9 to 3.13

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

### Python Version Upgrade Summary

| From → To | Key Action | Biggest Risk |
|-----------|-----------|--------------|
| 3.9 → 3.10 | Fix `distutils` usage, adopt pattern matching | `asyncio` loop parameter removal |
| 3.10 → 3.11 | Replace `toml` with `tomllib`, enjoy speed boost | `smtpd` removal |
| 3.11 → 3.12 | Remove `distutils`/`imp`, adopt type syntax | `distutils` full removal, sqlite3 adapter changes |
| 3.12 → 3.13 | Remove deprecated stdlib modules | Large number of removed stdlib modules |

---

## Node.js 18 to 22

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

### Node.js Version Upgrade Summary

| From → To | Key Action | Biggest Risk |
|-----------|-----------|--------------|
| 18 → 20 | Rebuild native modules, test URL parsing | Stricter URL validation, loader hooks off-thread |
| 20 → 22 | Rebuild native modules, check glibc version | Native module compatibility, header validation |

---

## TypeScript 4.x to 5.x

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

### Migration Strategy

```
TypeScript version upgrade approach:
│
├─ Minor version (5.x → 5.y)
│  └─ Generally safe, just update and fix new errors
│     npm install -D typescript@5.y
│     npx tsc --noEmit
│
└─ Major version (4.x → 5.x)
   ├─ 1. Update tsconfig.json (remove deleted options)
   ├─ 2. Install typescript@5
   ├─ 3. Run tsc --noEmit, fix errors
   ├─ 4. Decide on decorator strategy (legacy vs ECMAScript)
   └─ 5. Consider adopting moduleResolution: "bundler"
```

---

## Go 1.20 to 1.23

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

### Go Version Upgrade Summary

| From → To | Key Action | Biggest Risk |
|-----------|-----------|--------------|
| 1.20 → 1.21 | Update go.mod toolchain, adopt slog | Toolchain directive in go.mod |
| 1.21 → 1.22 | Enjoy loop variable fix, adopt enhanced routing | Loop variable semantics (usually fixes bugs) |
| 1.22 → 1.23 | Replace x/exp packages, adopt iterators | Timer/Ticker behavior change |

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

## PHP 8.1 to 8.4

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

### PHP Version Upgrade Summary

| From → To | Key Action | Biggest Risk |
|-----------|-----------|--------------|
| 8.1 → 8.2 | Fix dynamic properties, deprecation warnings | Dynamic properties deprecated |
| 8.2 → 8.3 | Adopt typed constants, #[Override] | array_sum/array_product behavior |
| 8.3 → 8.4 | Adopt property hooks, asymmetric visibility | Implicit nullable deprecation |

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
