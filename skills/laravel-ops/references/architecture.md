# Laravel Architecture Reference

Deep-dive reference for Laravel 11+ architecture: service container, providers, facades, middleware, events, notifications, jobs, scheduling, Blade, Livewire, and Inertia.

---

## Service Container

The container resolves class dependencies automatically via reflection.

### Binding Types

```php
// AppServiceProvider::register()

// Bind (new instance each resolution)
$this->app->bind(PaymentGateway::class, StripeGateway::class);
$this->app->bind(PaymentGateway::class, function ($app) {
    return new StripeGateway($app->make(HttpClient::class), config('stripe.key'));
});

// Singleton (same instance every resolution)
$this->app->singleton(AnalyticsService::class, function ($app) {
    return new AnalyticsService($app->make(Logger::class));
});

// Instance (bind a pre-existing object)
$this->app->instance(Config::class, new Config(['debug' => true]));

// Scoped (singleton per request lifecycle - useful with Octane)
$this->app->scoped(RequestContext::class, function ($app) {
    return new RequestContext($app->make(Request::class));
});
```

### Contextual Binding

```php
// Give different implementations to different classes
$this->app->when(PhotoController::class)
          ->needs(Filesystem::class)
          ->give(fn() => Storage::disk('photos'));

$this->app->when(VideoController::class)
          ->needs(Filesystem::class)
          ->give(fn() => Storage::disk('videos'));

// Bind tagged implementations
$this->app->bind(CsvReport::class, fn() => new CsvReport());
$this->app->bind(PdfReport::class, fn() => new PdfReport());
$this->app->tag([CsvReport::class, PdfReport::class], 'reports');

$reports = $this->app->tagged('reports'); // array of resolved instances
```

### Auto-Resolution and Method Injection

```php
// Constructor injection (auto-resolved)
class OrderService
{
    public function __construct(
        private readonly PaymentGateway $payment,
        private readonly InventoryRepository $inventory,
        private readonly EventDispatcher $events,
    ) {}
}

// Call with method injection
$result = app()->call([OrderService::class, 'process'], ['orderId' => 123]);

// Resolve with makeWith (pass primitives)
$service = app()->makeWith(ReportService::class, ['format' => 'pdf']);
```

---

## Service Providers

### Structure

```php
class AppServiceProvider extends ServiceProvider
{
    // Bindings array - simple alias
    public array $bindings = [
        OrderRepositoryInterface::class => EloquentOrderRepository::class,
    ];

    // Singletons array
    public array $singletons = [
        CurrencyConverter::class => CurrencyConverter::class,
    ];

    // register(): bind into container (no other services available yet)
    public function register(): void
    {
        $this->app->bind(PaymentGateway::class, fn($app) => new StripeGateway(
            config('services.stripe.key')
        ));
    }

    // boot(): everything is registered, safe to use facades and other services
    public function boot(): void
    {
        Model::preventLazyLoading(! $this->app->isProduction());
        Blade::directive('money', fn($amount) => "<?php echo money_format({$amount}); ?>");
        Post::observe(PostObserver::class);
        Validator::extend('phone', [PhoneValidator::class, 'validate']);
    }
}
```

### Deferred Providers

```php
// Only loaded when the binding is actually requested
class ReportServiceProvider extends ServiceProvider implements DeferrableProvider
{
    public function register(): void
    {
        $this->app->singleton(ReportGenerator::class, fn() => new ReportGenerator());
    }

    public function provides(): array
    {
        return [ReportGenerator::class]; // what this provider resolves
    }
}
```

### Package Service Providers

```php
class PackageServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->mergeConfigFrom(__DIR__.'/../config/package.php', 'package');
    }

    public function boot(): void
    {
        // Publish config
        $this->publishes([
            __DIR__.'/../config/package.php' => config_path('package.php'),
        ], 'config');

        // Publish migrations
        $this->publishes([
            __DIR__.'/../database/migrations' => database_path('migrations'),
        ], 'migrations');

        // Load migrations without publishing
        $this->loadMigrationsFrom(__DIR__.'/../database/migrations');

        // Load routes
        $this->loadRoutesFrom(__DIR__.'/../routes/web.php');

        // Load views (with namespace prefix)
        $this->loadViewsFrom(__DIR__.'/../resources/views', 'package');
    }
}
```

---

## Facades

Facades provide a static interface to services in the container.

```php
// How facades work internally
Cache::get('key');
// resolves to: app('cache')->get('key')

// Real-time facades (prefix with Facades\)
use Facades\App\Services\PaymentGateway;
PaymentGateway::charge($amount); // automatically resolved from container

// All standard facades
use Illuminate\Support\Facades\{
    App, Artisan, Auth, Blade, Bus, Cache, Config, Cookie, Crypt,
    DB, Event, File, Gate, Hash, Http, Log, Mail, Notification,
    Queue, Redirect, Request, Response, Route, Schema, Session,
    Storage, URL, Validator, View
};
```

### Testing with Facade Fakes

```php
// In test setup - swap real implementation with fake
Event::fake();
Mail::fake();
Notification::fake();
Queue::fake();
Bus::fake();
Storage::fake('s3');
Http::fake(['api.stripe.com/*' => Http::response(['id' => 'ch_123'], 200)]);

// Then assert interactions
Event::assertDispatched(OrderPlaced::class, fn($e) => $e->order->id === $orderId);
Event::assertNotDispatched(OrderCancelled::class);
Mail::assertSent(InvoiceMail::class, fn($mail) => $mail->hasTo('user@example.com'));
Notification::assertSentTo($user, InvoicePaidNotification::class);
Queue::assertPushed(ProcessPayment::class, fn($job) => $job->order->id === $orderId);
Queue::assertPushedOn('high-priority', ProcessPayment::class);
```

---

## Middleware

### Defining Middleware

```php
// php artisan make:middleware EnsureUserIsSubscribed

class EnsureUserIsSubscribed
{
    public function handle(Request $request, Closure $next): Response
    {
        if (! $request->user()?->subscribed()) {
            return redirect('/billing')->with('error', 'Subscription required.');
        }

        return $next($request);
    }
}

// Middleware with parameters
class EnsureRole
{
    public function handle(Request $request, Closure $next, string ...$roles): Response
    {
        if (! $request->user()->hasAnyRole($roles)) {
            abort(403);
        }
        return $next($request);
    }
}
// Route: Route::middleware('role:admin,editor')->group(...)
```

### Registering Middleware (Laravel 11+)

```php
// bootstrap/app.php
->withMiddleware(function (Middleware $middleware) {
    // Global middleware
    $middleware->append(LogHttpRequests::class);
    $middleware->prepend(TrustProxies::class);

    // Named middleware aliases
    $middleware->alias([
        'subscribed' => EnsureUserIsSubscribed::class,
        'role'       => EnsureRole::class,
    ]);

    // Middleware groups
    $middleware->group('api', [
        ThrottleRequests::class.':api',
        SubstituteBindings::class,
    ]);

    // Exclude from global middleware
    $middleware->except([VerifyCsrfToken::class], ['/webhooks/*']);
})
```

### Terminable Middleware

```php
// Runs AFTER response is sent (for cleanup, logging)
class LogResponseTime implements TerminableMiddleware
{
    private float $startTime;

    public function handle(Request $request, Closure $next): Response
    {
        $this->startTime = microtime(true);
        return $next($request);
    }

    public function terminate(Request $request, Response $response): void
    {
        $duration = microtime(true) - $this->startTime;
        Log::channel('performance')->info('Request completed', [
            'url'      => $request->fullUrl(),
            'duration' => round($duration * 1000, 2) . 'ms',
            'status'   => $response->getStatusCode(),
        ]);
    }
}
```

### Rate Limiting

```php
// AppServiceProvider::boot() or RouteServiceProvider
RateLimiter::for('api', function (Request $request) {
    return Limit::perMinute(60)->by($request->user()?->id ?: $request->ip());
});

RateLimiter::for('uploads', function (Request $request) {
    return [
        Limit::perMinute(10)->by($request->user()->id),     // per user
        Limit::perDay(100)->by($request->user()->id),       // daily cap
    ];
});

// Route-level: Route::middleware('throttle:api')->group(...)
```

---

## Events and Listeners

### Event Classes

```php
// php artisan make:event OrderPlaced
class OrderPlaced
{
    use Dispatchable, InteractsWithSockets, SerializesModels;

    public function __construct(
        public readonly Order $order,
        public readonly User $customer,
    ) {}

    // Broadcast over WebSockets (optional)
    public function broadcastOn(): array
    {
        return [new PrivateChannel("orders.{$this->order->id}")];
    }
}
```

### Listener Classes

```php
// php artisan make:listener SendOrderConfirmation --event=OrderPlaced
class SendOrderConfirmation implements ShouldQueue
{
    use InteractsWithQueue;

    public string $queue = 'notifications';
    public int $tries = 3;

    public function handle(OrderPlaced $event): void
    {
        Mail::to($event->customer)->send(new OrderConfirmationMail($event->order));
    }

    public function failed(OrderPlaced $event, Throwable $exception): void
    {
        Log::error('Failed to send order confirmation', ['order_id' => $event->order->id]);
    }
}
```

### Event Discovery (Laravel 11+)

```php
// bootstrap/app.php - auto-discover listeners in app/Listeners
->withEvents(function (Dispatcher $events) {
    $events->listen(OrderPlaced::class, SendOrderConfirmation::class);
    $events->listen(OrderPlaced::class, UpdateInventory::class);
    // Or enable auto-discovery:
    // $events->discover(app_path('Listeners'));
})

// Dispatch
OrderPlaced::dispatch($order, $user);
event(new OrderPlaced($order, $user));  // equivalent
```

---

## Notifications

### Notification Class

```php
// php artisan make:notification InvoicePaid
class InvoicePaid extends Notification implements ShouldQueue
{
    public function __construct(private readonly Invoice $invoice) {}

    // Which channels to send on
    public function via(object $notifiable): array
    {
        return $notifiable->prefers_sms
            ? ['mail', 'vonage']
            : ['mail', 'database'];
    }

    // Email channel
    public function toMail(object $notifiable): MailMessage
    {
        return (new MailMessage)
            ->subject("Invoice #{$this->invoice->number} paid")
            ->greeting("Hello {$notifiable->name},")
            ->line("Your invoice of {$this->invoice->amount_formatted} has been paid.")
            ->action('View Invoice', route('invoices.show', $this->invoice))
            ->line('Thank you for your business!');
    }

    // Database channel
    public function toDatabase(object $notifiable): array
    {
        return [
            'invoice_id' => $this->invoice->id,
            'amount'     => $this->invoice->amount,
            'paid_at'    => now()->toISOString(),
        ];
    }

    // Vonage (SMS) channel
    public function toVonage(object $notifiable): VonageMessage
    {
        return (new VonageMessage)
            ->content("Invoice #{$this->invoice->number} paid. Amount: {$this->invoice->amount_formatted}");
    }

    // Slack channel (via laravel/slack-notification-channel)
    public function toSlack(object $notifiable): SlackMessage
    {
        return (new SlackMessage)
            ->success()
            ->content("Invoice paid: #{$this->invoice->number}");
    }
}

// Sending
$user->notify(new InvoicePaid($invoice));               // via model
Notification::send($users, new InvoicePaid($invoice));  // to collection
Notification::route('mail', 'ops@app.com')              // on-demand
             ->notify(new InvoicePaid($invoice));

// Database notifications
$user->unreadNotifications;
$user->notifications()->markAsRead();
```

---

## Jobs and Queues

### Job Class Structure

```php
// php artisan make:job ProcessPayment
class ProcessPayment implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public int $tries = 3;
    public int $timeout = 90;
    public int $backoff = 60;           // seconds between retries
    public bool $deleteWhenMissingModels = true;

    public function __construct(
        private readonly Order $order,
        private readonly string $paymentMethodId,
    ) {}

    public function handle(PaymentGateway $gateway): void
    {
        // Re-fetch model (may have changed since dispatch)
        $order = Order::find($this->order->id);

        $charge = $gateway->charge($order->total, $this->paymentMethodId);
        $order->update(['payment_id' => $charge->id, 'status' => 'paid']);
        OrderPaid::dispatch($order);
    }

    // Exponential backoff per attempt
    public function backoff(): array
    {
        return [30, 60, 120]; // wait 30s, 60s, 120s between retries
    }

    // Called when all retries exhausted
    public function failed(Throwable $exception): void
    {
        $this->order->update(['status' => 'payment_failed']);
        Log::error('Payment failed', ['order_id' => $this->order->id, 'error' => $exception->getMessage()]);
    }

    // Middleware on job
    public function middleware(): array
    {
        return [
            new RateLimited('payments'),
            new WithoutOverlapping($this->order->id), // prevent duplicate processing
        ];
    }
}

// Dispatch patterns
ProcessPayment::dispatch($order, $paymentMethodId);
ProcessPayment::dispatch($order, $paymentMethodId)->onQueue('payments');
ProcessPayment::dispatch($order, $paymentMethodId)->delay(now()->addSeconds(30));
ProcessPayment::dispatchSync($order, $paymentMethodId); // synchronous (bypasses queue)
ProcessPayment::dispatchIf($order->requiresPayment(), $order, $paymentMethodId);
ProcessPayment::dispatchUnless($order->isFree(), $order, $paymentMethodId);
```

### Batches and Chains

```php
// Chain (sequential - each waits for previous to complete)
Bus::chain([
    new ValidateOrder($order),
    new ProcessPayment($order, $method),
    new SendConfirmation($order),
])->onQueue('orders')
  ->catch(fn(Throwable $e) => $order->markAsFailed($e->getMessage()))
  ->dispatch();

// Batch (parallel - all run concurrently)
$batch = Bus::batch(
    $rows->map(fn($row) => new ImportRow($row))->all()
)->then(function (Batch $batch) {
    ImportComplete::dispatch($batch->id);
})->catch(function (Batch $batch, Throwable $e) {
    Log::error('Batch failed', ['id' => $batch->id]);
})->finally(function (Batch $batch) {
    // always runs
})->name('CSV Import')
  ->allowFailures()          // don't cancel on single failure
  ->onQueue('imports')
  ->dispatch();

// Monitor batch
$batch = Bus::findBatch($batchId);
$batch->totalJobs;           // int
$batch->processedJobs();     // int
$batch->failedJobs;          // int
$batch->progress();          // 0-100
$batch->finished();          // bool
```

---

## Task Scheduling

```php
// routes/console.php (Laravel 11+)
use Illuminate\Support\Facades\Schedule;

// Frequency methods
Schedule::job(GenerateSitemap::class)->daily();
Schedule::job(SendNewsletters::class)->weekdays()->at('08:00');
Schedule::command('reports:monthly')->monthlyOn(1, '00:30');
Schedule::command('cache:prune')->everyFiveMinutes()->withoutOverlapping(10); // lock for 10 min max
Schedule::call(fn() => DB::table('logs')->where('created_at', '<', now()->subDays(90))->delete())
         ->weekly()->sundays();

// Output and notification
Schedule::command('backup:run')
         ->daily()
         ->runInBackground()
         ->appendOutputTo(storage_path('logs/backup.log'))
         ->emailOutputOnFailure('ops@app.com')
         ->pingOnSuccess(env('HEALTHCHECK_URL'));

// Run on one server (distributed lock via cache)
Schedule::job(SendDailyDigest::class)->daily()->onOneServer();

// Environment constraints
Schedule::command('sync:users')->hourly()->environments(['production']);

// Maintenance mode bypass
Schedule::job(HeartbeatCheck::class)->everyMinute()->evenInMaintenanceMode();

// Chained callbacks
Schedule::call(function () {
    // ...
})->before(fn() => Log::info('Starting'))
  ->after(fn() => Log::info('Complete'));
```

---

## Blade Components

### Anonymous Components

```blade
{{-- resources/views/components/alert.blade.php --}}
@props(['type' => 'info', 'dismissible' => false])

<div class="alert alert-{{ $type }} {{ $dismissible ? 'alert-dismissible' : '' }}">
    {{ $slot }}
    @if($dismissible)
        <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
    @endif
</div>

{{-- Usage --}}
<x-alert type="danger" dismissible>
    Something went wrong.
</x-alert>
```

### Named Slots

```blade
{{-- resources/views/components/modal.blade.php --}}
@props(['id', 'title'])

<div id="{{ $id }}" class="modal">
    <div class="modal-header">
        <h5>{{ $title }}</h5>
    </div>
    <div class="modal-body">
        {{ $slot }}
    </div>
    <div class="modal-footer">
        {{ $footer ?? '' }}
    </div>
</div>

{{-- Usage --}}
<x-modal id="confirm-delete" title="Confirm Delete">
    Are you sure you want to delete this item?

    <x-slot:footer>
        <button>Cancel</button>
        <button class="btn-danger">Delete</button>
    </x-slot:footer>
</x-modal>
```

### Class-Based Components

```php
// php artisan make:component UserCard
class UserCard extends Component
{
    public readonly string $initials;

    public function __construct(
        public readonly User $user,
        public bool $showEmail = false,
    ) {
        $this->initials = strtoupper(
            substr($user->first_name, 0, 1) . substr($user->last_name, 0, 1)
        );
    }

    public function render(): View
    {
        return view('components.user-card');
    }
}

{{-- resources/views/components/user-card.blade.php --}}
<div class="user-card">
    <div class="avatar">{{ $initials }}</div>
    <h3>{{ $user->name }}</h3>
    @if($showEmail)
        <p>{{ $user->email }}</p>
    @endif
</div>
```

### Stacks and Sections

```blade
{{-- layout.blade.php --}}
<html>
    <head>
        @stack('styles')       {{-- filled by child views --}}
    </head>
    <body>
        @yield('content')
        @stack('scripts')
    </body>
</html>

{{-- child.blade.php --}}
@extends('layout')

@push('styles')
    <link rel="stylesheet" href="/css/dashboard.css">
@endpush

@section('content')
    <h1>Dashboard</h1>
@endsection

@push('scripts')
    <script src="/js/dashboard.js"></script>
@endpush
```

---

## Livewire Integration

Livewire 3 handles server-side state with automatic DOM diffing.

### Component Structure

```php
// php artisan make:livewire SearchUsers

use Livewire\Attributes\{Computed, Url};
use Livewire\Component;

class SearchUsers extends Component
{
    #[Url]                          // syncs to query string
    public string $search = '';

    public string $sortBy = 'name';
    public bool $showModal = false;

    // Runs when $search changes (debounced in view)
    public function updatedSearch(): void
    {
        $this->resetPage();
    }

    // Computed property (cached per render)
    #[Computed]
    public function users(): LengthAwarePaginator
    {
        return User::where('name', 'like', "%{$this->search}%")
                   ->orderBy($this->sortBy)
                   ->paginate(10);
    }

    public function deleteUser(int $userId): void
    {
        $this->authorize('delete', User::find($userId));
        User::destroy($userId);
        $this->dispatch('user-deleted'); // JS event
    }

    public function render(): View
    {
        return view('livewire.search-users');
    }
}
```

```blade
{{-- resources/views/livewire/search-users.blade.php --}}
<div>
    <input wire:model.live.debounce.300ms="search" placeholder="Search...">

    <select wire:model.live="sortBy">
        <option value="name">Name</option>
        <option value="created_at">Newest</option>
    </select>

    @foreach($this->users as $user)
        <div wire:key="{{ $user->id }}">
            {{ $user->name }}
            <button wire:click="deleteUser({{ $user->id }})"
                    wire:confirm="Are you sure?">
                Delete
            </button>
        </div>
    @endforeach

    {{ $this->users->links() }}

    {{-- Lazy loading --}}
    <livewire:heavy-chart lazy />
</div>
```

### Livewire File Uploads

```php
use Livewire\WithFileUploads;

class UploadAvatar extends Component
{
    use WithFileUploads;

    #[Validate('image|max:1024')]
    public $photo;

    public function save(): void
    {
        $path = $this->photo->store('avatars', 's3');
        auth()->user()->update(['avatar' => $path]);
    }
}
```

---

## Inertia.js

Server-side routing + client-side rendering without a separate API.

### Laravel Side

```php
// Controller returns Inertia response
class PostController extends Controller
{
    public function index(): Response
    {
        return Inertia::render('Posts/Index', [
            'posts'  => PostResource::collection(Post::paginate(15)),
            'filters' => request()->only(['search', 'status']),
        ]);
    }

    // Lazy-loaded props (only sent when explicitly requested)
    public function show(Post $post): Response
    {
        return Inertia::render('Posts/Show', [
            'post'     => PostResource::make($post),
            'comments' => Inertia::lazy(fn() => CommentResource::collection($post->comments()->paginate(20))),
        ]);
    }

    // Redirect after form submission
    public function store(StorePostRequest $request): RedirectResponse
    {
        $post = Post::create($request->validated() + ['user_id' => auth()->id()]);
        return redirect()->route('posts.show', $post)->with('success', 'Post created.');
    }
}

// Shared data (available on every page)
// HandleInertiaRequests middleware
public function share(Request $request): array
{
    return [
        ...parent::share($request),
        'auth' => [
            'user' => $request->user()?->only('id', 'name', 'email'),
        ],
        'flash' => [
            'success' => $request->session()->get('success'),
            'error'   => $request->session()->get('error'),
        ],
    ];
}
```

### Vue Side (Inertia + Vue 3)

```vue
<!-- resources/js/Pages/Posts/Index.vue -->
<script setup>
import { ref } from 'vue'
import { router, useForm, usePage } from '@inertiajs/vue3'

const props = defineProps({
    posts: Object,
    filters: Object,
})

const page = usePage()
const auth = page.props.auth  // shared data

// Form helper
const form = useForm({
    title: '',
    body: '',
})

function submit() {
    form.post('/posts', {
        onSuccess: () => form.reset(),
    })
}

// Partial reloads (only refresh 'posts' prop)
function search(query) {
    router.get('/posts', { search: query }, {
        preserveState: true,
        only: ['posts'],
    })
}
</script>

<template>
    <div>
        <div v-for="post in posts.data" :key="post.id">
            <Link :href="`/posts/${post.id}`">{{ post.title }}</Link>
        </div>

        <!-- Inertia pagination links -->
        <Pagination :links="posts.links" />
    </div>
</template>
```

---

## Blade Directives and Helpers

### Authorization Directives

```blade
@auth
    <a href="/dashboard">Dashboard</a>
@endauth

@guest
    <a href="/login">Login</a>
@endguest

@can('update', $post)
    <a href="{{ route('posts.edit', $post) }}">Edit</a>
@endcan

@cannot('delete', $post)
    <p>You cannot delete this post.</p>
@endcannot

@role('admin')   {{-- if using spatie/laravel-permission --}}
    <a href="/admin">Admin Panel</a>
@endrole
```

### Looping Directives

```blade
@forelse($posts as $post)
    <article>{{ $post->title }}</article>
@empty
    <p>No posts found.</p>
@endforelse

{{-- Loop variable --}}
@foreach($items as $item)
    @if($loop->first) <ul> @endif
    <li class="{{ $loop->even ? 'even' : 'odd' }}">
        {{ $loop->iteration }}. {{ $item->name }}
    </li>
    @if($loop->last) </ul> @endif
@endforeach
```

### Custom Directives

```php
// AppServiceProvider::boot()
Blade::directive('currency', function ($expression) {
    return "<?php echo '$' . number_format({$expression}, 2); ?>";
});

Blade::if('env', function (string $environment) {
    return app()->environment($environment);
});
// Usage: @env('production') ... @endenv
```
