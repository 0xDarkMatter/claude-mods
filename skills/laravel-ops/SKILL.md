---
name: laravel-ops
description: "Laravel framework patterns, Eloquent ORM, authentication, queues, and testing. Use for: laravel, eloquent, artisan, blade, php, sanctum, livewire, inertia, pest, phpunit, forge, vapor, queue, middleware, migration, factory, seeder."
allowed-tools: "Read Write Bash"
related-skills: [sql-ops, postgres-ops, testing-ops, docker-ops]
---

# Laravel Operations

Authoritative reference for Laravel 11+ development: architecture decisions, Eloquent patterns, authentication strategies, queue configuration, and testing approaches.

---

## Architecture Decision Tree

```
What type of application?
│
├─ Full-stack web (HTML responses)
│  ├─ Simple CRUD, small team → Monolith (Blade + Eloquent directly)
│  │   └─ Use action classes for business logic over 20 lines
│  ├─ Rich interactivity needed → Livewire (server-driven reactivity)
│  │   └─ Add Alpine.js for client-side micro-interactions
│  └─ SPA-like feel, React/Vue team → Inertia.js
│      └─ Keep server-side routing, dump client-side routing overhead
│
├─ API backend (JSON responses)
│  ├─ Single consumer (mobile/SPA) → API-only with Sanctum SPA auth
│  ├─ Multiple consumers / public → RESTful API with token auth
│  └─ Complex graph queries → Consider GraphQL (lighthouse-php/lighthouse)
│
├─ Large team / complex domain
│  ├─ Domain-driven → Modular monolith (app/Modules/{Domain}/)
│  │   ├─ Each module: Models, Actions, Events, Jobs, Http/
│  │   └─ Shared: app/Shared/ for cross-cutting concerns
│  └─ Independent deployability needed → Microservices
│      └─ Use Laravel Octane for high-throughput services
│
└─ What business logic pattern?
   ├─ Simple CRUD, < 20 lines → Direct Eloquent in controller
   ├─ Reusable operation (create order, send invoice) → Action class
   │   └─ Single public handle() or execute() method
   ├─ Complex queries, multiple data sources → Repository pattern
   │   └─ Interface + Eloquent implementation (enables swapping)
   └─ Cross-cutting operations (audit, caching) → Service class
       └─ Inject via constructor, bind in ServiceProvider
```

### Action Class vs Repository vs Service

| Pattern | Use When | Example |
|---------|----------|---------|
| Action class | Single, reusable business operation | `CreateOrderAction`, `SendInvoiceAction` |
| Repository | Abstract data access, multiple sources | `OrderRepository` with `EloquentOrderRepository` |
| Service | Orchestrate multiple actions/repos | `OrderService` combining payment + inventory |
| Direct Eloquent | Simple CRUD, < 5 lines in controller | `User::create($data)` |

---

## Eloquent Quick Reference

### Relationships

| Relationship | Method | Foreign Key Convention |
|-------------|--------|----------------------|
| `hasOne` | `return $this->hasOne(Profile::class)` | `profiles.user_id` |
| `hasMany` | `return $this->hasMany(Post::class)` | `posts.user_id` |
| `belongsTo` | `return $this->belongsTo(User::class)` | `posts.user_id` |
| `belongsToMany` | `return $this->belongsToMany(Role::class)` | `role_user` pivot |
| `hasManyThrough` | `return $this->hasManyThrough(Post::class, User::class)` | Country → User → Post |
| `morphTo` | `return $this->morphTo()` | `{col}_type`, `{col}_id` |
| `morphMany` | `return $this->morphMany(Comment::class, 'commentable')` | Polymorphic |
| `morphToMany` | `return $this->morphToMany(Tag::class, 'taggable')` | Polymorphic pivot |

### Eager Loading

```php
// Prevent N+1: always eager load in controllers
$posts = Post::with(['author', 'comments.author', 'tags'])->paginate(15);

// Conditional eager loading (load after retrieval)
$user->load('posts.comments');
$user->loadMissing('posts'); // only if not already loaded

// Eager load counts (no SELECT *)
$posts = Post::withCount('comments')->get();

// Constrained eager loading
$posts = Post::with(['comments' => fn($q) => $q->approved()->latest()])->get();
```

### Query Scopes

```php
// Local scope (reusable query constraint)
public function scopeActive(Builder $query): void
{
    $query->where('status', 'active');
}

// Usage: User::active()->get()

// Dynamic scope
public function scopeOfType(Builder $query, string $type): void
{
    $query->where('type', $type);
}
// Usage: User::ofType('admin')->get()
```

### Mass Assignment

```php
// Fillable (allowlist - preferred)
protected $fillable = ['name', 'email', 'password'];

// Guarded (denylist - use [] only if you trust all input)
protected $guarded = ['id', 'is_admin'];

// Never set guarded = [] in production code
```

---

## Artisan Command Cheat Sheet

| Command | Purpose | Common Options |
|---------|---------|----------------|
| `make:model Post -mfs` | Model + migration + factory + seeder | `-c` controller, `-r` resource |
| `make:controller PostController -r` | Resource controller (7 methods) | `--api` skips create/edit |
| `make:request StorePostRequest` | Form request for validation | |
| `make:job ProcessPayment` | Queueable job class | `--sync` for sync job |
| `make:event OrderPlaced` | Event class | |
| `make:listener SendOrderConfirmation -e OrderPlaced` | Listener for event | `--queued` |
| `make:notification InvoicePaid` | Notification class | |
| `make:policy PostPolicy -m Post` | Policy with model | |
| `make:middleware EnsureUserIsAdmin` | HTTP middleware | |
| `make:command SendDailyReport` | Custom Artisan command | |
| `migrate` | Run pending migrations | `--step` for individual |
| `migrate:rollback` | Roll back last batch | `--step=5` |
| `migrate:fresh --seed` | Drop all + re-migrate + seed | |
| `db:seed` | Run all seeders | `--class=UserSeeder` |
| `tinker` | REPL with app context | |
| `route:list` | Show all routes | `--name=api` filter |
| `route:cache` | Cache routes for production | |
| `config:cache` | Cache config for production | |
| `view:cache` | Pre-compile Blade templates | |
| `optimize` | Run all cache commands | `optimize:clear` to reset |
| `queue:work` | Process queue jobs | `--queue=high,default` |
| `queue:listen` | Work + auto-reload on code change | |
| `queue:failed` | List failed jobs | |
| `queue:retry all` | Retry all failed jobs | |
| `schedule:run` | Run due scheduled tasks | |
| `schedule:work` | Run scheduler every minute (dev) | |
| `key:generate` | Generate APP_KEY | |
| `test` | Run PHPUnit/Pest tests | `--filter=UserTest` |
| `test --parallel` | Run tests in parallel | `--processes=4` |
| `vendor:publish` | Publish package assets/config | `--tag=config` |

---

## Authentication Decision Tree

```
What do you need?
│
├─ SPA (Vue/React) + Laravel API backend
│  └─ Sanctum SPA authentication
│     ├─ Cookie-based (same domain or subdomain)
│     ├─ Csrf-cookie endpoint: GET /sanctum/csrf-cookie
│     └─ No tokens in localStorage (XSS safe)
│
├─ Mobile app or third-party API consumers
│  └─ Sanctum API tokens (Bearer tokens)
│     ├─ createToken($name, $abilities)
│     ├─ Token abilities for fine-grained control
│     └─ Token expiration with token:prune schedule
│
├─ Traditional web app (server-rendered)
│  ├─ Just need auth pages quickly → Breeze
│  │   ├─ Minimal, educational, Blade or Inertia stack
│  │   └─ Install: composer require laravel/breeze --dev
│  ├─ Need teams, 2FA, profile management → Jetstream
│  │   ├─ Livewire or Inertia stack
│  │   └─ Install: composer require laravel/jetstream
│  └─ Need headless auth (API + custom UI) → Fortify
│      ├─ Actions in app/Actions/Fortify/
│      └─ Customize: CreateNewUser, UpdateUserPassword
│
└─ Custom / enterprise
   ├─ LDAP/SAML → socialiteproviders/saml2
   ├─ OAuth social login → laravel/socialite
   └─ Custom guard → Implement Guard + UserProvider contracts
```

### Sanctum Quick Setup

```php
// config/sanctum.php - stateful domains for SPA
'stateful' => explode(',', env('SANCTUM_STATEFUL_DOMAINS', 'localhost')),

// API token creation
$token = $user->createToken('mobile-app', ['orders:read', 'orders:write']);
return ['token' => $token->plainTextToken];

// Check token ability
Route::get('/orders', function (Request $request) {
    $request->user()->tokenCan('orders:read'); // bool
});

// Protect routes
Route::middleware('auth:sanctum')->group(function () {
    // authenticated routes
});
```

---

## Queue Decision Tree

```
Queue driver selection:
│
├─ Development / testing
│  └─ sync driver (executes immediately, no worker needed)
│     QUEUE_CONNECTION=sync
│
├─ Small app, no Redis available
│  └─ database driver
│     ├─ php artisan queue:table && migrate
│     ├─ Works fine for < 100 jobs/min
│     └─ QUEUE_CONNECTION=database
│
├─ Medium-high throughput, self-hosted
│  └─ Redis driver (via predis or phpredis)
│     ├─ QUEUE_CONNECTION=redis
│     ├─ Laravel Horizon for monitoring
│     └─ Supports priorities, pausing, metrics
│
└─ AWS infrastructure / massive scale
   └─ SQS driver
      ├─ QUEUE_CONNECTION=sqs
      ├─ Managed, auto-scaling
      └─ Use with Laravel Vapor for serverless
```

### Job Patterns

```php
// Basic job dispatch
ProcessPayment::dispatch($order);
ProcessPayment::dispatch($order)->onQueue('payments')->delay(now()->addMinutes(5));

// Chaining (sequential)
Bus::chain([
    new ProcessPayment($order),
    new SendInvoice($order),
    new UpdateInventory($order),
])->dispatch();

// Batching (parallel + callback)
$batch = Bus::batch([
    new ImportRow($row1),
    new ImportRow($row2),
    new ImportRow($row3),
])->then(fn(Batch $batch) => ImportComplete::dispatch())
  ->catch(fn(Batch $batch, Throwable $e) => Log::error($e))
  ->dispatch();

// Rate limiting (throttle to 5 per minute)
public function middleware(): array
{
    return [new RateLimited('payments')];
}

// Unique jobs (prevent duplicate processing)
use Illuminate\Contracts\Queue\ShouldBeUnique;

class ProcessPayment implements ShouldQueue, ShouldBeUnique
{
    public string $uniqueId => $this->order->id;
    public int $uniqueFor = 3600; // seconds
}

// Retry configuration
public int $tries = 3;
public int $backoff = 60; // seconds between retries

public function retryUntil(): DateTime
{
    return now()->addHours(24);
}
```

### Task Scheduling

```php
// routes/console.php (Laravel 11+)
Schedule::job(SendDailyReport::class)->dailyAt('08:00')->timezone('America/New_York');
Schedule::command('backup:run')->daily()->runInBackground()->emailOutputOnFailure('ops@app.com');
Schedule::call(fn() => Cache::flush())->weekly()->sundays()->at('00:00');

// Prevent overlap (long-running tasks)
Schedule::job(ProcessImport::class)->everyFiveMinutes()->withoutOverlapping();

// Run on one server only (requires Redis/database cache driver)
Schedule::job(SendNewsletters::class)->daily()->onOneServer();
```

---

## Testing Quick Reference

### Test Types

| Type | Class extends | Database | Purpose |
|------|--------------|----------|---------|
| Feature test | `Tests\TestCase` | Yes (with trait) | HTTP endpoints, full stack |
| Unit test | `PHPUnit\Framework\TestCase` | No | Pure logic, no app boot |
| Browser test | `Laravel\Dusk\TestCase` | Yes | Real browser via ChromeDriver |

### Database Traits

```php
use Illuminate\Foundation\Testing\RefreshDatabase;   // migrate fresh each test (slower)
use Illuminate\Foundation\Testing\DatabaseTransactions; // rollback each test (faster)
```

### Pest Syntax (preferred in Laravel 11+)

```php
describe('User authentication', function () {
    beforeEach(function () {
        $this->user = User::factory()->create();
    });

    it('allows login with valid credentials', function () {
        $response = $this->post('/login', [
            'email' => $this->user->email,
            'password' => 'password',
        ]);

        $response->assertRedirect('/dashboard');
        $this->assertAuthenticatedAs($this->user);
    });

    it('rejects invalid credentials')->todo();
});
```

### Common Assertions

```php
// HTTP response
$response->assertStatus(200);
$response->assertOk();             // 200
$response->assertCreated();        // 201
$response->assertNoContent();      // 204
$response->assertUnauthorized();   // 401
$response->assertForbidden();      // 403
$response->assertNotFound();       // 404
$response->assertRedirect('/home');

// JSON responses
$response->assertJson(['status' => 'ok']);
$response->assertJsonPath('data.email', 'user@example.com');
$response->assertJsonCount(3, 'data');
$response->assertJsonStructure(['data' => ['id', 'name', 'email']]);
$response->assertJsonMissing(['password']);

// Database
$this->assertDatabaseHas('users', ['email' => 'user@example.com']);
$this->assertDatabaseMissing('users', ['email' => 'deleted@example.com']);
$this->assertDatabaseCount('posts', 5);
$this->assertSoftDeleted('posts', ['id' => $post->id]);
```

---

## Common Gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| N+1 queries on relationships | Eloquent lazy-loads by default | Use `with()` eager loading; enable `Model::preventLazyLoading()` in AppServiceProvider during development |
| Mass assignment vulnerability | `$fillable = []` accepts all | Always define `$fillable`; never use `$guarded = []` in production |
| `created_at` not updating on `update()` | Only `updated_at` auto-sets | Use `$model->touch()` or `timestamps = true` (default) |
| Queue job fails on model serialization | Model state may change between dispatch and processing | Use `SerializesModels` trait; re-fetch from DB in `handle()` if needed |
| Timezone mismatch in scheduled tasks | Server tz != app tz | Set `APP_TIMEZONE` in `.env`; use `->timezone()` on schedule entries |
| Middleware order matters | Auth middleware must run before policies | Global → route group → route. Auth before throttle check or vice versa changes 401 vs 429 |
| Route model binding skips soft-deleted records | `RouteServiceProvider` ignores `trashed()` | Extend binding: `Route::bind('post', fn($id) => Post::withTrashed()->findOrFail($id))` |
| Service container binding not auto-resolved | Interface not bound to implementation | Register in `AppServiceProvider::register()`: `$this->app->bind(Interface::class, Implementation::class)` |
| Migration foreign key order | Must create referenced table first | Run `migrate:fresh` to verify; use `Schema::disableForeignKeyConstraints()` in tests |
| CSRF protection blocks API routes | `VerifyCsrfToken` runs on all web routes | Register API routes in `routes/api.php` (uses `api` middleware group without CSRF) |
| `env()` returns null after caching | `config:cache` bakes env values | Always access env via `config()` helper in app code; only use `env()` in `config/` files |
| Blade `@stack` renders in wrong order | `@push` must appear after `@stack` in execution | Use `@prepend` for scripts that must appear first |
| Event listener not firing | Listener not registered or discovered | Check `EventServiceProvider::$listen`; or enable `Event::discover()` in Laravel 11 |

---

## Reference Files

| File | Contents |
|------|---------|
| `references/eloquent-queries.md` | Deep-dive: relationships, query builder, scopes, accessors, mutators, events, soft deletes, pagination, performance, collections, factories |
| `references/architecture.md` | Service container, providers, facades, middleware, events, notifications, jobs, scheduling, Blade components, Livewire, Inertia |
| `references/testing-auth.md` | PHPUnit/Pest setup, HTTP tests, database testing, fakes, Sanctum, Fortify, policies, form requests, Dusk |

---

## See Also

- `sql-ops` - Query optimization, indexing strategy, raw SQL patterns
- `postgres-ops` - PostgreSQL-specific features, JSON columns, full-text search
- `testing-ops` - General testing philosophy, TDD, CI integration
- `docker-ops` - Containerizing Laravel apps, Docker Compose, production setup

### Key External Resources

- [Laravel 11 Documentation](https://laravel.com/docs/11.x)
- [Pest PHP](https://pestphp.com/)
- [Laravel Horizon](https://laravel.com/docs/11.x/horizon) - Queue monitoring
- [Laravel Octane](https://laravel.com/docs/11.x/octane) - High-performance serving
- [Laravel Forge](https://forge.laravel.com/) - Server management
- [Laravel Vapor](https://vapor.laravel.com/) - Serverless deployment
