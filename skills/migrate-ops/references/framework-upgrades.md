# Framework Upgrade Paths

Detailed upgrade procedures for major framework version transitions.

---

## React 18 to 19

### Pre-Upgrade Checklist

```
[ ] Running React 18.3.x (last 18.x with deprecation warnings)
[ ] All deprecation warnings resolved
[ ] No usage of legacy string refs
[ ] No usage of legacy context (contextTypes)
[ ] No usage of defaultProps on function components
[ ] No usage of propTypes at runtime
[ ] Test suite passing on 18.3.x
[ ] TypeScript 5.x or later (for type changes)
```

### Step-by-Step Process

1. **Upgrade to React 18.3.x first** -- this version surfaces deprecation warnings for all APIs removed in 19.
2. **Fix all deprecation warnings** before proceeding.
3. **Run the official codemod:**
   ```bash
   npx codemod@latest react/19/migration-recipe --target src/
   ```
4. **Update package.json:**
   ```bash
   npm install react@19 react-dom@19
   npm install -D @types/react@19 @types/react-dom@19
   ```
5. **Update react-dom entry point:**
   ```tsx
   // Before (React 18)
   import { createRoot } from 'react-dom/client';
   // After (React 19) -- same API, but check for removed APIs below
   ```
6. **Run tests and fix remaining issues.**

### Breaking Changes

| Removed API | Replacement |
|------------|-------------|
| `forwardRef` | Pass `ref` as a regular prop |
| `<Context.Provider>` | Use `<Context>` directly as provider |
| `defaultProps` on function components | Use JS default parameters |
| `propTypes` runtime checking | Use TypeScript or Flow |
| `react-test-renderer` | Use `@testing-library/react` |
| `ReactDOM.render` | Use `createRoot` (already required in 18) |
| `ReactDOM.hydrate` | Use `hydrateRoot` (already required in 18) |
| `unmountComponentAtNode` | Use `root.unmount()` |
| `ReactDOM.findDOMNode` | Use refs |

### New APIs to Adopt

```tsx
// use() hook -- read promises and context in render
import { use } from 'react';

function UserProfile({ userPromise }: { userPromise: Promise<User> }) {
  const user = use(userPromise);
  return <h1>{user.name}</h1>;
}

// useActionState -- form action with state
import { useActionState } from 'react';

function LoginForm() {
  const [state, formAction, isPending] = useActionState(
    async (prev: State, formData: FormData) => {
      const result = await login(formData);
      return result;
    },
    { error: null }
  );
  return <form action={formAction}>...</form>;
}

// useOptimistic -- optimistic updates
import { useOptimistic } from 'react';

function TodoList({ todos }: { todos: Todo[] }) {
  const [optimisticTodos, addOptimistic] = useOptimistic(
    todos,
    (state, newTodo: Todo) => [...state, newTodo]
  );
  // ...
}

// ref as prop -- no more forwardRef
function Input({ ref, ...props }: { ref?: React.Ref<HTMLInputElement> }) {
  return <input ref={ref} {...props} />;
}

// Context as provider
const ThemeContext = createContext('light');
// Before: <ThemeContext.Provider value="dark">
// After:
<ThemeContext value="dark">
  <App />
</ThemeContext>
```

### Verification Steps

```bash
# Run type checking
npx tsc --noEmit

# Run tests
npm test

# Search for removed APIs that codemods may have missed
rg "forwardRef" src/
rg "Context\.Provider" src/
rg "defaultProps" src/ --glob "*.tsx"
rg "propTypes" src/ --glob "*.tsx"
rg "findDOMNode" src/
rg "react-test-renderer" package.json
```

---

## Next.js Pages Router to App Router

### Pre-Upgrade Checklist

```
[ ] Running latest Next.js 14.x or 15.x
[ ] Understood Server vs Client Component model
[ ] Identified pages that need client-side interactivity
[ ] Reviewed data fetching strategy (no more getServerSideProps/getStaticProps)
[ ] Identified API routes that need migration
[ ] Middleware already using edge runtime (if applicable)
```

### Step-by-Step Process

1. **Create `app/` directory** alongside existing `pages/`.
2. **Create `app/layout.tsx`** (replaces `_app.tsx` and `_document.tsx`):
   ```tsx
   export default function RootLayout({ children }: { children: React.ReactNode }) {
     return (
       <html lang="en">
         <body>{children}</body>
       </html>
     );
   }
   ```
3. **Migrate pages one at a time** -- both routers work simultaneously.
4. **Convert data fetching:**
   ```tsx
   // Before (Pages Router)
   export async function getServerSideProps() {
     const data = await fetchData();
     return { props: { data } };
   }
   export default function Page({ data }) { ... }

   // After (App Router)
   export default async function Page() {
     const data = await fetchData(); // direct async component
     return <div>{data}</div>;
   }
   ```
5. **Convert dynamic routes:**
   ```
   pages/posts/[id].tsx  →  app/posts/[id]/page.tsx
   pages/[...slug].tsx   →  app/[...slug]/page.tsx
   ```
6. **Run the official codemod:**
   ```bash
   npx @next/codemod@latest
   ```

### File Convention Changes

| Pages Router | App Router | Purpose |
|-------------|-----------|---------|
| `pages/index.tsx` | `app/page.tsx` | Home page |
| `pages/about.tsx` | `app/about/page.tsx` | Static page |
| `pages/posts/[id].tsx` | `app/posts/[id]/page.tsx` | Dynamic page |
| `pages/_app.tsx` | `app/layout.tsx` | Root layout |
| `pages/_document.tsx` | `app/layout.tsx` | HTML document |
| `pages/_error.tsx` | `app/error.tsx` | Error boundary |
| `pages/404.tsx` | `app/not-found.tsx` | Not found page |
| `pages/api/hello.ts` | `app/api/hello/route.ts` | API route |
| N/A | `app/loading.tsx` | Loading UI (new) |
| N/A | `app/template.tsx` | Re-mounted layout (new) |

### Data Fetching Migration

| Pages Router | App Router |
|-------------|-----------|
| `getServerSideProps` | `async` Server Component (fetches on every request) |
| `getStaticProps` | `async` Server Component + `fetch` with `cache: 'force-cache'` |
| `getStaticPaths` | `generateStaticParams()` |
| `getInitialProps` | Remove entirely -- use Server Components |
| `useRouter().query` | `useSearchParams()` (client) or `searchParams` prop (server) |

### Common Breaking Changes

- `useRouter` from `next/navigation` not `next/router`
- `pathname` no longer includes query parameters
- `Link` no longer requires `<a>` child
- CSS Modules class names may differ
- `Image` component default behavior changes
- Metadata API replaces `<Head>` component
- Route handlers replace API routes (different request/response model)

### Verification Steps

```bash
# Check for Pages Router imports in migrated files
rg "from 'next/router'" app/
rg "getServerSideProps|getStaticProps|getInitialProps" app/
rg "next/head" app/

# Verify all routes work
npm run build  # catches most issues at build time
npm run dev    # test interactive behavior
```

---

## Vue 2 to 3

### Pre-Upgrade Checklist

```
[ ] Identified all breaking syntax changes (v-model, filters, events)
[ ] Listed third-party Vue 2 plugins that need Vue 3 equivalents
[ ] Decided on migration approach: migration build (@vue/compat) vs direct
[ ] Decided on state management: Vuex → Pinia migration
[ ] Test suite passing on Vue 2
```

### Step-by-Step Process (Using Migration Build)

1. **Upgrade to Vue 2.7** first (backports Composition API, `<script setup>`).
2. **Start adopting Composition API** in Vue 2.7 where convenient.
3. **Switch to Vue 3 + @vue/compat:**
   ```bash
   npm install vue@3 @vue/compat
   ```
4. **Configure compat mode** in bundler (Vite or Webpack):
   ```js
   // vite.config.js
   export default {
     resolve: {
       alias: { vue: '@vue/compat' }
     }
   };
   ```
5. **Fix compatibility warnings** one category at a time.
6. **Remove `@vue/compat`** once all warnings are resolved.

### Breaking Changes

| Vue 2 | Vue 3 | Notes |
|-------|-------|-------|
| `v-model` (default) | `v-model` uses `modelValue` prop + `update:modelValue` event | Custom `model` option removed |
| `v-bind.sync` | `v-model:propName` | `.sync` modifier removed |
| Filters `{{ value \| filter }}` | Methods or computed | Filters removed entirely |
| `$on`, `$off`, `$once` | External library (mitt) | Event bus pattern removed |
| `Vue.component()` global | `app.component()` | Global API restructured |
| `Vue.use()` | `app.use()` | Plugin installation |
| `Vue.mixin()` | `app.mixin()` or Composition API | Global mixins |
| `Vue.filter()` | N/A | Filters removed |
| `this.$set` / `Vue.set` | Direct assignment | Reactivity system rewritten (Proxy-based) |
| `this.$delete` / `Vue.delete` | `delete obj.prop` | Proxy handles this |
| `$listeners` | Merged into `$attrs` | Separate `$listeners` removed |
| `$children` | Template refs | Direct child access removed |
| `<transition>` class names | `v-enter-from` / `v-leave-from` | `-active` suffix retained |

### Vuex to Pinia Migration

```ts
// Vuex (old)
const store = createStore({
  state: { count: 0 },
  mutations: { increment(state) { state.count++; } },
  actions: { asyncIncrement({ commit }) { commit('increment'); } },
  getters: { doubleCount: (state) => state.count * 2 }
});

// Pinia (new)
export const useCounterStore = defineStore('counter', () => {
  const count = ref(0);
  const doubleCount = computed(() => count.value * 2);
  function increment() { count.value++; }
  async function asyncIncrement() { increment(); }
  return { count, doubleCount, increment, asyncIncrement };
});
```

### Available Codemods

```bash
# Vue official codemod
npx @vue/codemod src/

# Specific transforms
npx @vue/codemod src/ --transform vue-class-component-v8
npx @vue/codemod src/ --transform new-global-api
npx @vue/codemod src/ --transform vue-router-v4
```

### Verification Steps

```bash
# Search for Vue 2 patterns
rg "\$on\(|\.sync|Vue\.component|Vue\.use|Vue\.mixin" src/
rg "this\.\$set|this\.\$delete|this\.\$children" src/
rg "filters:" src/ --glob "*.vue"
rg "v-bind\.sync" src/ --glob "*.vue"

# Build and test
npm run build
npm test
```

---

## Laravel 10 to 11

### Pre-Upgrade Checklist

```
[ ] Running PHP 8.2+ (Laravel 11 requires PHP 8.2 minimum)
[ ] All tests passing on Laravel 10
[ ] Reviewed Laravel 11 release notes
[ ] Identified custom service providers that need updates
[ ] Checked third-party package Laravel 11 compatibility
```

### Step-by-Step Process

1. **Use Laravel Shift** (recommended, paid automated service):
   ```
   https://laravelshift.com
   ```
2. **Or manual upgrade -- update composer.json:**
   ```json
   {
     "require": {
       "laravel/framework": "^11.0"
     }
   }
   ```
3. **Run composer update:**
   ```bash
   composer update
   ```
4. **Apply skeleton changes** (Laravel 11 uses a slimmer skeleton):
   - `bootstrap/app.php` is simplified
   - Many config files removed from `config/` (use defaults)
   - Service providers consolidated
   - Middleware moved to `bootstrap/app.php`
   - `app/Http/Kernel.php` removed
5. **Fix deprecation warnings and test.**

### Breaking Changes

| Laravel 10 | Laravel 11 | Notes |
|-----------|-----------|-------|
| `app/Http/Kernel.php` | `bootstrap/app.php` | Middleware registration moved |
| Multiple service providers | Single `AppServiceProvider` | Consolidated providers |
| Full `config/` directory | Minimal config (publish as needed) | `php artisan config:publish` to restore |
| Console `Kernel.php` | `routes/console.php` with closures | Schedule defined in `routes/console.php` |
| Exception handler class | `bootstrap/app.php` withExceptions() | Exception handling consolidated |
| `$schedule->command()->everyMinute()` | `->everySecond()` now available | Per-second scheduling added |
| Explicit casts property | `casts()` method on model | Method-based casting |

### New Features to Adopt

```php
// Per-second scheduling
Schedule::command('check:pulse')->everySecond();

// Dumpable trait
use Illuminate\Support\Traits\Dumpable;

class MyService {
    use Dumpable;
    // Now supports ->dd() and ->dump() chaining
}

// Method-based casts
protected function casts(): array {
    return [
        'options' => AsArrayObject::class,
        'created_at' => 'datetime:Y-m-d',
    ];
}

// Simplified bootstrap/app.php
return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        api: __DIR__.'/../routes/api.php',
    )
    ->withMiddleware(function (Middleware $middleware) {
        $middleware->web(append: [CustomMiddleware::class]);
    })
    ->withExceptions(function (Exceptions $exceptions) {
        $exceptions->report(function (SomeException $e) {
            // custom reporting
        });
    })
    ->create();
```

### Verification Steps

```bash
# Check for removed patterns
rg "class Kernel extends HttpKernel" app/
rg "class Handler extends ExceptionHandler" app/

# Run tests
php artisan test

# Check config
php artisan config:show

# Verify routes
php artisan route:list
```

---

## Angular Version Upgrades

### Pre-Upgrade Checklist

```
[ ] Check Angular Update Guide: https://update.angular.io
[ ] Running the latest patch of current major version
[ ] All tests passing
[ ] No deprecated APIs in use (check ng build warnings)
[ ] Third-party libraries checked for target version compatibility
```

### Step-by-Step Process

1. **Check the update guide** for your specific version jump:
   ```
   https://update.angular.io/?from=16.0&to=17.0
   ```
2. **Run ng update** for core packages:
   ```bash
   ng update @angular/core @angular/cli
   ```
3. **Run ng update** for additional Angular packages:
   ```bash
   ng update @angular/material  # if using Material
   ng update @angular/router    # if needed
   ```
4. **Review and apply schematics** that ng update runs automatically.
5. **Fix any remaining issues** and run tests.

### Recent Major Changes by Version

| Version | Key Changes |
|---------|-------------|
| **14** | Standalone components, typed forms, inject() function |
| **15** | Standalone APIs stable, directive composition, image optimization |
| **16** | Signals (developer preview), required inputs, esbuild builder |
| **17** | Signals stable, deferrable views, built-in control flow, esbuild default |
| **18** | Zoneless change detection (experimental), Material 3, fallback content |
| **19** | Standalone by default, linked signals, resource API, incremental hydration |

### Common Pitfalls

- **RxJS version**: Angular often requires specific RxJS versions. Check compatibility.
- **TypeScript version**: Each Angular major requires a specific TS range.
- **Zone.js**: Being phased out in favor of signals. Plan accordingly.
- **Module vs Standalone**: Newer versions push toward standalone components.

### Verification Steps

```bash
ng build --configuration=production
ng test
ng e2e

# Check for deprecation warnings in build output
ng build 2>&1 | rg -i "deprecated|warning"
```

---

## Django Version Upgrades

### Pre-Upgrade Checklist

```
[ ] Running the latest patch of current major version
[ ] All deprecation warnings resolved
[ ] Tests passing with python -Wd (warnings as errors)
[ ] Third-party packages checked for target version support
[ ] Database migrations up to date
```

### Step-by-Step Process

1. **Enable deprecation warnings:**
   ```bash
   python -Wd manage.py test
   ```
2. **Fix all deprecation warnings** on current version.
3. **Read release notes** for target version:
   ```
   https://docs.djangoproject.com/en/5.0/releases/
   ```
4. **Update Django:**
   ```bash
   pip install Django==5.0
   ```
5. **Run django-upgrade codemod:**
   ```bash
   pip install django-upgrade
   django-upgrade --target-version 5.0 $(fd -e py)
   ```
6. **Run tests and fix issues.**

### Recent Major Changes by Version

| Version | Key Changes |
|---------|-------------|
| **4.0** | Redis cache backend, `scrypt` hasher, template-based form rendering |
| **4.1** | Async ORM, `async` view support, validation of model constraints |
| **4.2** | Psycopg 3, `STORAGES` setting, custom file storage |
| **5.0** | Facet filters in admin, simplified templates, database-computed default |
| **5.1** | LoginRequiredMiddleware, connection pool for PostgreSQL |

### Available Codemods

```bash
# django-upgrade: automated fixes
pip install django-upgrade
django-upgrade --target-version 5.0 **/*.py

# Specific transforms handled:
# - url() to path() in urlconfs
# - @admin.register decorator
# - HttpResponse charset parameter
# - Deprecated model field arguments
```

### Verification Steps

```bash
# Full test suite with warnings
python -Wd manage.py test

# Check for deprecated imports
rg "from django.utils.encoding import force_text" .
rg "from django.conf.urls import url" .
rg "from django.utils.translation import ugettext" .

# Verify migrations
python manage.py makemigrations --check
python manage.py migrate --run-syncdb

# Check system
python manage.py check --deploy
```

---

## Cross-Framework Migration Checklist

Regardless of which framework you are upgrading, follow this universal checklist after the migration is complete:

```
Post-Migration Verification
│
├─ [ ] All tests pass (unit, integration, e2e)
├─ [ ] Build succeeds in production mode
├─ [ ] No deprecation warnings in build output
├─ [ ] Bundle size compared to pre-migration baseline
├─ [ ] Performance benchmarks compared to pre-migration baseline
├─ [ ] Error monitoring shows no new error types
├─ [ ] All pages/routes load correctly (smoke test)
├─ [ ] Forms and user interactions work
├─ [ ] Authentication and authorization work
├─ [ ] Third-party integrations verified
├─ [ ] CI/CD pipeline updated for new version
├─ [ ] Docker/deployment images updated
├─ [ ] Documentation updated (README, setup guide)
└─ [ ] Team notified of completed migration
```
