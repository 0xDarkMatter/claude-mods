# Testing and Authentication Reference

Deep-dive reference for PHPUnit/Pest testing, Sanctum, Fortify, policies, form requests, and browser testing with Dusk.

---

## PHPUnit Setup

### phpunit.xml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<phpunit xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:noNamespaceSchemaLocation="vendor/phpunit/phpunit/phpunit.xsd"
         bootstrap="vendor/autoload.php"
         colors="true">
    <testsuites>
        <testsuite name="Unit">
            <directory suffix="Test.php">./tests/Unit</directory>
        </testsuite>
        <testsuite name="Feature">
            <directory suffix="Test.php">./tests/Feature</directory>
        </testsuite>
    </testsuites>

    <source>
        <include>
            <directory suffix=".php">./app</directory>
        </include>
    </source>

    <php>
        <env name="APP_ENV" value="testing"/>
        <env name="APP_KEY" value="base64:test-key-32-chars-here-padded"/>
        <env name="CACHE_STORE" value="array"/>
        <env name="DB_CONNECTION" value="sqlite"/>
        <env name="DB_DATABASE" value=":memory:"/>
        <env name="MAIL_MAILER" value="array"/>
        <env name="QUEUE_CONNECTION" value="sync"/>
        <env name="SESSION_DRIVER" value="array"/>
    </php>
</phpunit>
```

### Test Databases

```php
// Option 1: SQLite in-memory (fastest)
// .env.testing
DB_CONNECTION=sqlite
DB_DATABASE=:memory:

// Option 2: Separate MySQL test database
DB_CONNECTION=mysql
DB_DATABASE=app_testing

// Option 3: Per-test transaction rollback (fastest for MySQL)
use Illuminate\Foundation\Testing\DatabaseTransactions;

// Option 4: Migrate fresh per test class (safest, slowest)
use Illuminate\Foundation\Testing\RefreshDatabase;
```

---

## Pest PHP (Preferred in Laravel 11+)

### Project Setup

```bash
composer require pestphp/pest pestphp/pest-plugin-laravel --dev
php artisan pest:install
```

### File Structure and Syntax

```php
// tests/Feature/PostTest.php
use App\Models\{Post, User};
use Illuminate\Foundation\Testing\RefreshDatabase;

uses(RefreshDatabase::class);

// Group related tests
describe('Post creation', function () {
    beforeEach(function () {
        $this->user = User::factory()->create();
        $this->actingAs($this->user);
    });

    it('creates a post with valid data', function () {
        $response = $this->post('/posts', [
            'title' => 'My First Post',
            'body'  => 'Post content here.',
        ]);

        $response->assertRedirect();
        $this->assertDatabaseHas('posts', ['title' => 'My First Post']);
    });

    it('requires a title', function () {
        $response = $this->post('/posts', ['body' => 'Content']);
        $response->assertInvalid(['title']);
    });

    it('is pending future implementation')->todo();
});

// Top-level tests
test('guests cannot create posts', function () {
    $this->post('/posts', ['title' => 'Test'])->assertRedirect('/login');
});
```

### Pest Expectations

```php
// Chained expectations
expect($value)
    ->toBeTrue()
    ->not->toBeNull()
    ->toEqual('expected')
    ->toBeString()
    ->toHaveCount(3)
    ->toContain('substring')
    ->toMatchArray(['key' => 'value'])
    ->toHaveKey('name')
    ->toHaveKeys(['id', 'name', 'email'])
    ->toBeBetween(1, 10)
    ->toBeGreaterThan(5)
    ->toBeLessThanOrEqual(100)
    ->toBeInstanceOf(User::class)
    ->toBeNull()
    ->toBeEmpty()
    ->toThrow(InvalidArgumentException::class, 'message');

// Higher-order expectations
expect([1, 2, 3])->each->toBeInt();
expect($users)->each->toBeInstanceOf(User::class);

// Expectations on collections
expect($users)->sequence(
    fn($user) => $user->name->toBe('Alice'),
    fn($user) => $user->name->toBe('Bob'),
);
```

### Datasets

```php
it('validates email format', function (string $email, bool $valid) {
    $response = $this->post('/register', ['email' => $email]);

    if ($valid) {
        $response->assertValid(['email']);
    } else {
        $response->assertInvalid(['email']);
    }
})->with([
    ['valid@example.com', true],
    ['not-an-email', false],
    ['missing@', false],
    ['@nodomain.com', false],
]);

// Shared datasets
// tests/Datasets/emails.php
dataset('invalid_emails', ['not-email', '@nodomain', 'missing@tld']);
```

### Architectural Testing

```php
// tests/Architecture/AppTest.php
arch('controllers do not use Eloquent directly')
    ->expect('App\Http\Controllers')
    ->not->toUse(['Illuminate\Database\Eloquent\Model']);

arch('actions are invokable')
    ->expect('App\Actions')
    ->toBeClasses()
    ->toHaveSuffix('Action');

arch('models extend Eloquent')
    ->expect('App\Models')
    ->toExtend('Illuminate\Database\Eloquent\Model');

arch('no debug functions in production code')
    ->expect('App')
    ->not->toUse(['dd', 'dump', 'ray', 'var_dump']);
```

---

## HTTP Tests

### Basic HTTP Testing

```php
// GET requests
$response = $this->get('/posts');
$response = $this->getJson('/api/posts');           // sets Accept: application/json

// POST / PUT / PATCH / DELETE
$response = $this->post('/posts', $data);
$response = $this->postJson('/api/posts', $data);
$response = $this->put('/posts/1', $data);
$response = $this->patch('/posts/1', ['status' => 'published']);
$response = $this->delete('/posts/1');

// With headers
$response = $this->withHeaders(['X-Custom-Header' => 'value'])->get('/api/data');

// With cookies
$response = $this->withCookie('token', 'abc')->get('/dashboard');

// Follow redirects
$response = $this->followingRedirects()->post('/posts', $data);
```

### Response Assertions

```php
// Status codes
$response->assertOk();                                    // 200
$response->assertCreated();                               // 201
$response->assertAccepted();                              // 202
$response->assertNoContent();                             // 204
$response->assertMovedPermanently();                      // 301
$response->assertFound();                                 // 302
$response->assertNotModified();                           // 304
$response->assertBadRequest();                            // 400
$response->assertUnauthorized();                          // 401
$response->assertPaymentRequired();                       // 402
$response->assertForbidden();                             // 403
$response->assertNotFound();                              // 404
$response->assertMethodNotAllowed();                      // 405
$response->assertUnprocessable();                         // 422
$response->assertTooManyRequests();                       // 429
$response->assertServerError();                           // 500
$response->assertStatus(418);                             // custom

// Redirect
$response->assertRedirect('/home');
$response->assertRedirectToRoute('dashboard');
$response->assertRedirectContains('/orders');

// View
$response->assertViewIs('posts.index');
$response->assertViewHas('posts');
$response->assertViewHas('user', fn($user) => $user->id === 1);
$response->assertSee('Hello World');
$response->assertSeeText('Hello World');                  // strips HTML
$response->assertDontSee('Error');

// JSON
$response->assertJson(['status' => 'ok', 'data' => ['id' => 1]]);
$response->assertJsonFragment(['email' => 'user@example.com']);
$response->assertJsonPath('data.user.name', 'John');
$response->assertJsonPath('data.*.id', [1, 2, 3]);
$response->assertJsonCount(3, 'data');
$response->assertJsonStructure([
    'data' => [
        '*' => ['id', 'title', 'created_at'],
    ],
    'meta' => ['total', 'per_page'],
]);
$response->assertJsonMissing(['password', 'remember_token']);
$response->assertExactJson(['key' => 'value']);           // exact match

// Headers and cookies
$response->assertHeader('Content-Type', 'application/json');
$response->assertCookie('session');
$response->assertCookieMissing('auth_token');

// Session
$response->assertSessionHas('success');
$response->assertSessionHasErrors(['email', 'password']);
$response->assertSessionMissing('error');

// Validation errors
$response->assertValid(['name', 'email']);
$response->assertInvalid(['email' => 'invalid email format']);
```

---

## Database Testing

### Traits

```php
use Illuminate\Foundation\Testing\RefreshDatabase;
// Migrates fresh for every test class (drops + re-migrates). Slower but safe.

use Illuminate\Foundation\Testing\DatabaseTransactions;
// Wraps each test in a transaction, rolls back. Fast, but doesn't work with external processes.

use Illuminate\Foundation\Testing\DatabaseMigrations;
// Migrates before the test suite, rolls back after. Per-file.
```

### Database Assertions

```php
$this->assertDatabaseHas('users', [
    'email' => 'user@example.com',
    'role'  => 'admin',
]);

$this->assertDatabaseMissing('users', [
    'email' => 'deleted@example.com',
]);

$this->assertDatabaseCount('posts', 5);

$this->assertSoftDeleted('posts', ['id' => $post->id]);
$this->assertNotSoftDeleted('posts', ['id' => $post->id]);

$this->assertDatabaseEmpty('cache');

// Model-based assertions
$this->assertModelExists($post);
$this->assertModelMissing($deletedPost);
```

### Factory Usage in Tests

```php
// Create persisted records
$user = User::factory()->create();
$user = User::factory()->admin()->create(['name' => 'Override Name']);

// Create without persisting
$user = User::factory()->make();

// Create multiple
$users = User::factory()->count(5)->create();

// Create with relationships
$post = Post::factory()
    ->for(User::factory()->admin())
    ->hasComments(3)
    ->withTags(5)
    ->create();

// Seed specific data
$this->seed(RoleSeeder::class);
$this->seed([RoleSeeder::class, PermissionSeeder::class]);
```

---

## Mocking Facades

### Mail

```php
Mail::fake();

$this->post('/checkout', $orderData);

Mail::assertSent(OrderConfirmationMail::class);
Mail::assertSent(OrderConfirmationMail::class, 1);        // sent exactly once
Mail::assertSent(OrderConfirmationMail::class, fn($mail) =>
    $mail->hasTo('customer@example.com') &&
    $mail->hasSubject('Your Order Confirmation')
);
Mail::assertNotSent(RefundMail::class);
Mail::assertQueued(WeeklyNewsletterMail::class);           // queued, not sent
Mail::assertNothingSent();
```

### Notification

```php
Notification::fake();

$this->post('/orders', $data);

Notification::assertSentTo($user, InvoicePaidNotification::class);
Notification::assertSentTo($user, InvoicePaidNotification::class, fn($n) =>
    $n->invoice->id === $invoiceId
);
Notification::assertNotSentTo($admin, InvoicePaidNotification::class);
Notification::assertCount(2);
Notification::assertNothingSent();

// On-demand notifications
Notification::assertSentOnDemand(AlertNotification::class, fn($n, $routes) =>
    $routes->hasRoute('mail', 'ops@example.com')
);
```

### Event

```php
Event::fake();
// Or fake only specific events:
Event::fake([OrderPlaced::class, PaymentProcessed::class]);

$this->post('/orders', $data);

Event::assertDispatched(OrderPlaced::class);
Event::assertDispatched(OrderPlaced::class, fn($e) => $e->order->id === $orderId);
Event::assertDispatchedTimes(StockUpdated::class, 3);
Event::assertNotDispatched(OrderCancelled::class);
Event::assertListening(OrderPlaced::class, SendOrderConfirmation::class);
Event::assertNothingDispatched();
```

### Queue / Bus

```php
Queue::fake();

$this->post('/upload', $fileData);

Queue::assertPushed(ProcessUpload::class);
Queue::assertPushed(ProcessUpload::class, fn($job) => $job->filename === 'test.csv');
Queue::assertPushedOn('imports', ProcessUpload::class);
Queue::assertNotPushed(NotifyAdmin::class);
Queue::assertCount(2);
Queue::assertNothingPushed();

// Bus for batches and chains
Bus::fake();
Bus::assertChained([ValidateData::class, ProcessData::class, NotifyUser::class]);
Bus::assertBatched(fn($batch) => $batch->jobs->count() === 100);
```

### HTTP Client

```php
Http::fake([
    'api.stripe.com/v1/charges' => Http::response([
        'id'     => 'ch_123',
        'status' => 'succeeded',
    ], 200),
    'api.sendgrid.com/*' => Http::response(['message' => 'success'], 202),
    '*' => Http::response('Not mocked', 404),  // catch-all
]);

// Simulate failure
Http::fake(['api.stripe.com/*' => Http::response(['error' => 'declined'], 402)]);

// Sequence of responses
Http::fake([
    'api.example.com/*' => Http::sequence()
        ->push(['data' => []],  200)
        ->push(['data' => [1]], 200)
        ->pushStatus(429),      // rate limit on 3rd call
]);

// Assert requests were made
Http::assertSent(fn($request) =>
    $request->url() === 'https://api.stripe.com/v1/charges' &&
    $request['amount'] === 2000
);
Http::assertSentCount(3);
Http::assertNotSent(fn($request) => str_contains($request->url(), 'sendgrid'));
```

### Storage

```php
Storage::fake('s3');

$this->post('/avatars', ['photo' => UploadedFile::fake()->image('photo.jpg')]);

Storage::disk('s3')->assertExists('avatars/photo.jpg');
Storage::disk('s3')->assertMissing('avatars/old.jpg');
```

---

## Sanctum Authentication

### API Token Authentication

```php
// Installation
composer require laravel/sanctum
php artisan vendor:publish --provider="Laravel\Sanctum\SanctumServiceProvider"
php artisan migrate

// User model
use Laravel\Sanctum\HasApiTokens;
class User extends Authenticatable { use HasApiTokens; }

// Issue token (login endpoint)
$token = $user->createToken('mobile-app', ['orders:read', 'orders:write']);
return response()->json(['token' => $token->plainTextToken]);

// Check abilities
$user->tokenCan('orders:read');   // bool
$user->currentAccessToken();      // PersonalAccessToken model

// Token expiration (config/sanctum.php)
'expiration' => 60 * 24 * 7,      // 7 days in minutes

// Revoke tokens
$user->tokens()->delete();         // all tokens
$user->currentAccessToken()->delete(); // current only
```

### Testing with Sanctum

```php
use Laravel\Sanctum\Sanctum;

// Authenticate as user (no real token needed)
Sanctum::actingAs($user);
Sanctum::actingAs($user, ['orders:read', 'orders:write']); // with abilities

// Feature test examples
it('returns orders for authenticated user', function () {
    Sanctum::actingAs(User::factory()->create(), ['orders:read']);
    Order::factory()->count(3)->for(auth()->user())->create();

    $this->getJson('/api/orders')
         ->assertOk()
         ->assertJsonCount(3, 'data');
});

it('rejects requests without valid token', function () {
    $this->getJson('/api/orders')->assertUnauthorized();
});

it('enforces token abilities', function () {
    Sanctum::actingAs(User::factory()->create(), ['orders:read']); // no write ability
    $this->postJson('/api/orders', $data)->assertForbidden();
});
```

### SPA Authentication (Cookie-based)

```php
// Frontend must first hit GET /sanctum/csrf-cookie
// Then POST /login with credentials
// Subsequent requests use session cookie + X-XSRF-TOKEN header

// config/sanctum.php
'stateful' => explode(',', env('SANCTUM_STATEFUL_DOMAINS', 'localhost,localhost:3000')),

// routes/api.php
Route::middleware('auth:sanctum')->get('/user', fn(Request $request) => $request->user());

// CORS (config/cors.php)
'paths'             => ['api/*', 'sanctum/csrf-cookie'],
'allowed_origins'   => ['http://localhost:3000'],
'supports_credentials' => true,
```

---

## Fortify (Headless Authentication)

```bash
composer require laravel/fortify
php artisan vendor:publish --provider="Laravel\Fortify\FortifyServiceProvider"
php artisan migrate
```

### Configuration

```php
// config/fortify.php
'features' => [
    Features::registration(),
    Features::resetPasswords(),
    Features::emailVerification(),
    Features::updateProfileInformation(),
    Features::updatePasswords(),
    Features::twoFactorAuthentication([
        'confirm'        => true,
        'confirmPassword' => true,
    ]),
],
```

### Customizing Actions

```php
// app/Actions/Fortify/CreateNewUser.php
class CreateNewUser implements CreatesNewUsers
{
    public function create(array $input): User
    {
        Validator::make($input, [
            'name'     => ['required', 'string', 'max:255'],
            'email'    => ['required', 'email', 'unique:users'],
            'password' => ['required', Password::defaults(), 'confirmed'],
        ])->validate();

        return DB::transaction(function () use ($input) {
            $user = User::create([
                'name'     => $input['name'],
                'email'    => $input['email'],
                'password' => Hash::make($input['password']),
            ]);
            $user->assignRole('user');                    // spatie/laravel-permission
            event(new Registered($user));
            return $user;
        });
    }
}

// FortifyServiceProvider::boot()
Fortify::createUsersUsing(CreateNewUser::class);
Fortify::updateUserProfileInformationUsing(UpdateUserProfileInformation::class);
Fortify::updateUserPasswordsUsing(UpdateUserPassword::class);
Fortify::resetUserPasswordsUsing(ResetUserPassword::class);
```

---

## Policies and Gates

### Defining a Policy

```php
// php artisan make:policy PostPolicy --model=Post
class PostPolicy
{
    // Gates receive user as first arg (nullable for guests)
    public function viewAny(?User $user): bool
    {
        return true; // anyone can list posts
    }

    public function view(?User $user, Post $post): bool
    {
        return $post->is_published || $user?->id === $post->user_id;
    }

    public function create(User $user): bool
    {
        return $user->hasVerifiedEmail();
    }

    public function update(User $user, Post $post): bool
    {
        return $user->id === $post->user_id || $user->isAdmin();
    }

    public function delete(User $user, Post $post): bool
    {
        return $user->id === $post->user_id || $user->isAdmin();
    }

    public function restore(User $user, Post $post): bool
    {
        return $user->isAdmin();
    }

    public function forceDelete(User $user, Post $post): bool
    {
        return $user->isAdmin();
    }
}
```

### Registering Policies (Laravel 11+ auto-discovery)

```php
// Auto-discovered if model/policy naming convention followed
// OR manual registration in AppServiceProvider::boot():
Gate::policy(Post::class, PostPolicy::class);
```

### Using Policies

```php
// Controller
class PostController extends Controller
{
    public function update(Request $request, Post $post): RedirectResponse
    {
        $this->authorize('update', $post);
        // ...
    }

    // Resource controller - authorize all methods at once
    public function __construct()
    {
        $this->authorizeResource(Post::class, 'post');
    }
}

// Route-level middleware
Route::put('/posts/{post}', [PostController::class, 'update'])
     ->middleware('can:update,post');

// Blade
@can('update', $post) ... @endcan
@cannot('delete', $post) ... @endcannot

// Manual check
if (Gate::allows('update', $post)) { ... }
if (Gate::denies('delete', $post)) { abort(403); }

// Before all policy checks (super-admin bypass)
Gate::before(fn(User $user) => $user->isSuperAdmin() ? true : null);
```

### Testing Policies

```php
it('allows post author to update their post', function () {
    $user = User::factory()->create();
    $post = Post::factory()->for($user)->create();

    $this->actingAs($user)
         ->put("/posts/{$post->id}", ['title' => 'Updated'])
         ->assertOk();
});

it('prevents non-author from updating post', function () {
    $author  = User::factory()->create();
    $visitor = User::factory()->create();
    $post    = Post::factory()->for($author)->create();

    $this->actingAs($visitor)
         ->put("/posts/{$post->id}", ['title' => 'Hacked'])
         ->assertForbidden();
});
```

---

## Form Requests

### Request Class

```php
// php artisan make:request StorePostRequest
class StorePostRequest extends FormRequest
{
    // Who can make this request?
    public function authorize(): bool
    {
        return $this->user()->hasVerifiedEmail();
    }

    // Validation rules
    public function rules(): array
    {
        return [
            'title'       => ['required', 'string', 'min:5', 'max:255'],
            'body'        => ['required', 'string', 'min:50'],
            'status'      => ['required', Rule::in(['draft', 'published'])],
            'tags'        => ['nullable', 'array', 'max:5'],
            'tags.*'      => ['integer', 'exists:tags,id'],
            'image'       => ['nullable', 'image', 'max:2048', 'mimes:jpg,png,webp'],
            'published_at' => ['nullable', 'date', 'after:now', Rule::requiredIf($this->status === 'published')],
        ];
    }

    // Transform input before validation
    public function prepareForValidation(): void
    {
        $this->merge([
            'slug'   => Str::slug($this->title ?? ''),
            'status' => $this->status ?? 'draft',
        ]);
    }

    // Custom error messages
    public function messages(): array
    {
        return [
            'title.required' => 'A post title is required.',
            'body.min'       => 'Posts must be at least 50 characters.',
        ];
    }

    // Custom attribute names in error messages
    public function attributes(): array
    {
        return [
            'published_at' => 'publication date',
        ];
    }

    // After validation hook (complex cross-field validation)
    public function after(): array
    {
        return [
            function (Validator $validator) {
                if ($this->hasFile('image') && $this->status === 'draft') {
                    $validator->errors()->add('image', 'Images cannot be added to draft posts.');
                }
            },
        ];
    }

    // Safe data for controller use
    // $request->validated() - only validated fields
    // $request->safe()->only(['title', 'body']) - subset
    // $request->safe()->except(['tags']) - exclude
}
```

### Testing Form Requests

```php
it('creates a post with valid data', function () {
    $user = User::factory()->verified()->create();

    $this->actingAs($user)->postJson('/posts', [
        'title'  => 'A Valid Post Title',
        'body'   => str_repeat('a', 50), // meet min:50
        'status' => 'draft',
    ])->assertCreated();
});

it('requires a title', function () {
    $this->actingAs(User::factory()->verified()->create())
         ->postJson('/posts', ['body' => str_repeat('a', 50), 'status' => 'draft'])
         ->assertUnprocessable()
         ->assertJsonValidationErrors(['title']);
});

// Test the form request class directly (unit test)
it('validates correctly', function () {
    $request = StorePostRequest::create('/posts', 'POST', [
        'title'  => 'Valid Title',
        'body'   => str_repeat('a', 50),
        'status' => 'draft',
    ]);

    $validator = Validator::make($request->all(), (new StorePostRequest)->rules());
    expect($validator->fails())->toBeFalse();
});
```

---

## Middleware Testing

```php
// Test route with middleware applied
it('redirects unauthenticated users', function () {
    $this->get('/dashboard')->assertRedirect('/login');
});

// Test with middleware excluded
it('processes request without auth in test', function () {
    $response = $this->withoutMiddleware(Authenticate::class)->get('/dashboard');
    $response->assertOk();
});

// Exclude all middleware
$this->withoutMiddleware()->get('/dashboard');

// Exclude CSRF for POST tests (alternative to using withHeaders)
// Usually unnecessary if using postJson() or RefreshDatabase
```

---

## Browser Testing with Dusk

### Setup

```bash
composer require laravel/dusk --dev
php artisan dusk:install
# Update APP_URL in .env.dusk.local
# Start Chrome: php artisan dusk:chrome-driver
# Run tests: php artisan dusk
```

### Test Structure

```php
// tests/Browser/LoginTest.php
use Laravel\Dusk\Browser;
use Tests\DuskTestCase;

class LoginTest extends DuskTestCase
{
    public function test_user_can_login(): void
    {
        $user = User::factory()->create(['password' => Hash::make('password')]);

        $this->browse(function (Browser $browser) use ($user) {
            $browser->visit('/login')
                    ->type('email', $user->email)
                    ->type('password', 'password')
                    ->press('Login')
                    ->assertPathIs('/dashboard')
                    ->assertSee('Welcome back');
        });
    }

    public function test_user_can_upload_avatar(): void
    {
        $user = User::factory()->create();

        $this->browse(function (Browser $browser) use ($user) {
            $browser->loginAs($user)
                    ->visit('/settings/profile')
                    ->attach('avatar', __DIR__.'/../fixtures/avatar.jpg')
                    ->press('Save')
                    ->assertSee('Profile updated');
        });
    }
}
```

### Dusk Selectors and Assertions

```php
$browser
    ->visit('/posts')
    ->assertTitle('Posts - My App')
    ->assertSee('Latest Posts')
    ->assertDontSee('Error')
    ->click('@create-post-btn')             // dusk="create-post-btn" attribute
    ->pause(500)                            // ms - prefer waitFor instead
    ->waitFor('.modal', 5)                  // wait up to 5s
    ->waitForText('Post created')
    ->waitUntilMissing('.spinner')
    ->assertVisible('#post-form')
    ->assertMissing('.error-message')
    ->type('input[name=title]', 'My Post')
    ->select('select[name=status]', 'published')
    ->check('input[name=featured]')
    ->uncheck('input[name=notify]')
    ->radio('input[name=type]', 'article')
    ->screenshot('after-form-fill')         // saves to tests/Browser/screenshots/
    ->assertInputValue('title', 'My Post')
    ->assertChecked('featured')
    ->press('Submit')
    ->assertPathIs('/posts')
    ->assertRouteIs('posts.index');

// JavaScript execution
$browser->script('document.querySelector(".modal").remove()');
$value = $browser->value('#hidden-input');

// Multiple browsers (for real-time features)
$this->browse(function (Browser $alice, Browser $bob) {
    $alice->loginAs($this->user)->visit('/chat');
    $bob->loginAs($this->otherUser)->visit('/chat')
        ->type('#message', 'Hello!')
        ->press('Send');
    $alice->waitForText('Hello!')->assertSee('Hello!');
});
```

---

## Test Helpers and Utilities

### Custom Test Helpers

```php
// tests/TestCase.php - add reusable methods
abstract class TestCase extends BaseTestCase
{
    protected function signIn(?User $user = null): User
    {
        $user ??= User::factory()->create();
        $this->actingAs($user);
        return $user;
    }

    protected function signInAsAdmin(): User
    {
        $admin = User::factory()->admin()->create();
        $this->actingAs($admin);
        return $admin;
    }

    protected function assertValidationError(TestResponse $response, string $field): void
    {
        $response->assertUnprocessable()
                 ->assertJsonValidationErrors([$field]);
    }
}
```

### Parallel Testing

```bash
# Run tests in parallel (requires brianium/paratest)
composer require brianium/paratest --dev
php artisan test --parallel
php artisan test --parallel --processes=4
```

```php
// Use separate test database per process
// phpunit.xml: <env name="DB_DATABASE" value="app_testing_${TEST_TOKEN}"/>
// Or configure in ParallelRunner
```

### Test-Specific Configuration

```php
// .env.testing overrides
MAIL_MAILER=array
QUEUE_CONNECTION=sync
CACHE_STORE=array
SESSION_DRIVER=array

// Per-test config override
Config::set('mail.default', 'array');
Config::set('queue.default', 'sync');

// Freeze time (Carbon)
$this->travelTo(now()->setDate(2024, 1, 15));
$this->travelBack();
Carbon::setTestNow('2024-01-15 12:00:00');
Carbon::setTestNow();   // reset
```
