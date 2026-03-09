# Eloquent Queries Reference

Deep-dive reference for Eloquent ORM: relationships, query builder, scopes, accessors, mutators, events, soft deletes, pagination, performance, collections, and factories.

---

## Relationships

### hasOne

```php
// User hasOne Profile
class User extends Model
{
    public function profile(): HasOne
    {
        return $this->hasOne(Profile::class);
        // Convention: profiles.user_id
        // Custom: $this->hasOne(Profile::class, 'foreign_key', 'local_key')
    }
}

// Usage
$profile = $user->profile;                    // lazy load
$user = User::with('profile')->find(1);       // eager load
$user->profile()->create(['bio' => '...']);   // create via relationship
```

### hasMany

```php
class User extends Model
{
    public function posts(): HasMany
    {
        return $this->hasMany(Post::class);
    }
}

// Usage
$posts = $user->posts;                        // Collection
$posts = $user->posts()->published()->get();  // chained query
$user->posts()->createMany([
    ['title' => 'First'],
    ['title' => 'Second'],
]);
```

### belongsTo

```php
class Post extends Model
{
    public function author(): BelongsTo
    {
        return $this->belongsTo(User::class, 'user_id'); // explicit FK
    }
}

// Avoid null when accessing author before saving
$post->author()->associate($user); // sets user_id
$post->save();

// Dissociate (set FK to null)
$post->author()->dissociate();
$post->save();
```

### belongsToMany (many-to-many with pivot)

```php
class User extends Model
{
    public function roles(): BelongsToMany
    {
        return $this->belongsToMany(Role::class)
                    ->withPivot('assigned_at', 'assigned_by')
                    ->withTimestamps()
                    ->using(RoleUser::class); // custom pivot model
    }
}

// Pivot model with extra attributes
class RoleUser extends Pivot
{
    protected $casts = [
        'assigned_at' => 'datetime',
    ];
}

// Attach / detach / sync
$user->roles()->attach($roleId, ['assigned_by' => auth()->id()]);
$user->roles()->detach($roleId);
$user->roles()->sync([1, 2, 3]);                    // replaces all
$user->roles()->syncWithoutDetaching([4, 5]);       // additive only
$user->roles()->toggle([1, 2]);                     // attach if not, detach if yes

// Querying pivot
$user->roles()->wherePivot('assigned_by', $userId)->get();

// Access pivot in result
foreach ($user->roles as $role) {
    echo $role->pivot->assigned_at;
}
```

### hasManyThrough

```php
// Country → User → Post (access posts through users)
class Country extends Model
{
    public function posts(): HasManyThrough
    {
        return $this->hasManyThrough(
            Post::class,  // final model
            User::class,  // intermediate model
            'country_id', // FK on users table
            'user_id',    // FK on posts table
            'id',         // local key on countries
            'id'          // local key on users
        );
    }
}
```

### hasOneThrough

```php
// Mechanic → Car → CarOwner (through single intermediary)
class Mechanic extends Model
{
    public function carOwner(): HasOneThrough
    {
        return $this->hasOneThrough(Owner::class, Car::class);
    }
}
```

### Polymorphic: morphTo / morphMany

```php
// Comment can belong to Post or Video
class Comment extends Model
{
    public function commentable(): MorphTo
    {
        return $this->morphTo(); // uses commentable_type + commentable_id
    }
}

class Post extends Model
{
    public function comments(): MorphMany
    {
        return $this->morphMany(Comment::class, 'commentable');
    }
}

class Video extends Model
{
    public function comments(): MorphMany
    {
        return $this->morphMany(Comment::class, 'commentable');
    }
}

// Usage
$post->comments()->create(['body' => 'Great post!']);
$comment->commentable; // returns Post or Video instance

// Morph map (cleaner DB values)
// AppServiceProvider::boot()
Relation::morphMap([
    'post'  => Post::class,
    'video' => Video::class,
]);
```

### morphToMany (polymorphic many-to-many)

```php
// Post and Video can have many Tags
class Post extends Model
{
    public function tags(): MorphToMany
    {
        return $this->morphToMany(Tag::class, 'taggable');
        // pivot: taggables (taggable_id, taggable_type, tag_id)
    }
}

class Tag extends Model
{
    public function posts(): MorphedByMany
    {
        return $this->morphedByMany(Post::class, 'taggable');
    }
}
```

---

## Query Builder

### Basic Constraints

```php
// Where clauses
User::where('status', 'active')
    ->where('age', '>=', 18)
    ->orWhere('is_admin', true)
    ->get();

// whereIn / whereNotIn
Post::whereIn('status', ['published', 'featured'])->get();
Post::whereNotIn('user_id', [1, 2, 3])->get();

// whereNull / whereNotNull
User::whereNull('deleted_at')->get();
User::whereNotNull('email_verified_at')->get();

// whereBetween
Order::whereBetween('total', [100, 500])->get();

// whereDate / whereYear / whereMonth / whereDay
Post::whereDate('created_at', '2024-01-15')->get();
Post::whereYear('created_at', 2024)->get();

// whereColumn (compare two columns)
Order::whereColumn('shipped_at', '>', 'ordered_at')->get();
```

### Relationship Constraints

```php
// whereHas: filter models with related models matching condition
Post::whereHas('comments', function (Builder $query) {
    $query->where('approved', true);
})->get();

// whereDoesntHave
Post::whereDoesntHave('comments')->get(); // posts with no comments

// withWhereHas: eager load + constrain simultaneously
Post::withWhereHas('comments', fn($q) => $q->approved())->get();

// whereHas with count
Post::whereHas('comments', fn($q) => $q, '>=', 5)->get(); // at least 5 comments
```

### Subqueries

```php
// Select subquery
$users = User::addSelect([
    'last_login_at' => Login::select('created_at')
        ->whereColumn('user_id', 'users.id')
        ->latest()
        ->limit(1),
])->get();

// orderBy subquery
$users = User::orderByDesc(
    Login::select('created_at')
        ->whereColumn('user_id', 'users.id')
        ->latest()
        ->limit(1)
)->get();

// From subquery
$orders = DB::table(function (Builder $query) {
    $query->from('orders')->where('status', 'shipped');
}, 'shipped_orders')->get();
```

### Raw Expressions

```php
// selectRaw
User::selectRaw('COUNT(*) as total, DATE(created_at) as date')
    ->groupByRaw('DATE(created_at)')
    ->get();

// whereRaw
User::whereRaw('LOWER(email) = ?', [strtolower($email)])->first();

// orderByRaw
Post::orderByRaw('FIELD(status, "featured", "published", "draft")')->get();

// havingRaw
User::selectRaw('country, COUNT(*) as total')
    ->groupBy('country')
    ->havingRaw('COUNT(*) > ?', [100])
    ->get();
```

---

## Query Scopes

### Local Scopes

```php
class Post extends Model
{
    // Constraint scope
    public function scopePublished(Builder $query): void
    {
        $query->where('status', 'published')
              ->whereNotNull('published_at');
    }

    // Dynamic scope with parameter
    public function scopeByStatus(Builder $query, string $status): void
    {
        $query->where('status', $status);
    }

    // Scope with optional parameter
    public function scopeRecent(Builder $query, int $days = 7): void
    {
        $query->where('created_at', '>=', now()->subDays($days));
    }
}

// Usage (chaining scopes)
Post::published()->recent(30)->orderByDesc('published_at')->paginate(15);
Post::byStatus('draft')->get();
```

### Global Scopes

```php
// Define scope class
class ActiveScope implements Scope
{
    public function apply(Builder $builder, Model $model): void
    {
        $builder->where('active', true);
    }
}

// Apply globally (in model boot or via attribute in Laravel 11+)
class User extends Model
{
    protected static function booted(): void
    {
        static::addGlobalScope(new ActiveScope());
        // Or anonymous: static::addGlobalScope('active', fn(Builder $b) => $b->where('active', true));
    }
}

// Removing global scope for specific query
User::withoutGlobalScope(ActiveScope::class)->get();
User::withoutGlobalScope('active')->get();
User::withoutGlobalScopes()->get(); // remove all
```

---

## Accessors and Mutators (Laravel 11+ Attribute Class)

```php
use Illuminate\Database\Eloquent\Casts\Attribute;

class User extends Model
{
    // Accessor only
    protected function fullName(): Attribute
    {
        return Attribute::make(
            get: fn() => "{$this->first_name} {$this->last_name}",
        );
    }

    // Mutator only
    protected function password(): Attribute
    {
        return Attribute::make(
            set: fn(string $value) => bcrypt($value),
        );
    }

    // Accessor + Mutator
    protected function name(): Attribute
    {
        return Attribute::make(
            get: fn(string $value) => ucfirst($value),
            set: fn(string $value) => strtolower($value),
        )->withoutObjectCaching(); // recompute each access
    }
}

// Usage
$user->full_name;       // "John Doe"
$user->password = 'secret'; // automatically hashed
```

### Built-in Casts

```php
protected $casts = [
    'is_admin'       => 'boolean',
    'score'          => 'float',
    'metadata'       => 'array',          // JSON column ↔ array
    'preferences'    => 'collection',      // JSON ↔ Collection
    'settings'       => AsArrayObject::class,    // JSON ↔ ArrayObject (mutable)
    'options'        => AsCollection::class,     // JSON ↔ Collection (mutable)
    'secret'         => 'encrypted',       // transparent encryption
    'secret_array'   => 'encrypted:array', // encrypted JSON
    'birthday'       => 'date',            // Carbon without time
    'published_at'   => 'datetime',        // Carbon with time
    'status'         => PostStatus::class, // PHP 8.1 enum
];
```

### Enum Casting (PHP 8.1+)

```php
enum PostStatus: string
{
    case Draft     = 'draft';
    case Published = 'published';
    case Archived  = 'archived';
}

class Post extends Model
{
    protected $casts = [
        'status' => PostStatus::class,
    ];
}

// Usage
$post->status = PostStatus::Published; // or 'published'
$post->status->label();                // if you add methods to enum
Post::where('status', PostStatus::Published)->get();
```

---

## Eloquent Events

### Model Lifecycle Events

| Event | Fires When |
|-------|-----------|
| `creating` | Before INSERT (can cancel with false) |
| `created` | After INSERT |
| `updating` | Before UPDATE (can cancel with false) |
| `updated` | After UPDATE |
| `saving` | Before INSERT or UPDATE |
| `saved` | After INSERT or UPDATE |
| `deleting` | Before DELETE (can cancel with false) |
| `deleted` | After DELETE |
| `restoring` | Before restore (soft delete) |
| `restored` | After restore |
| `retrieved` | After SELECT (heavy use discouraged) |

### Registering Listeners

```php
// Option 1: $dispatchesEvents on model
class Post extends Model
{
    protected $dispatchesEvents = [
        'created'  => PostCreated::class,
        'deleted'  => PostDeleted::class,
    ];
}

// Option 2: boot() method (for closures)
class Post extends Model
{
    protected static function booted(): void
    {
        static::creating(function (Post $post) {
            $post->slug = Str::slug($post->title);
        });

        static::deleting(function (Post $post) {
            $post->comments()->delete(); // cascade via Eloquent
        });
    }
}
```

### Observer Classes

```php
// php artisan make:observer PostObserver --model=Post

class PostObserver
{
    public function creating(Post $post): void
    {
        $post->slug = Str::slug($post->title);
        $post->user_id ??= auth()->id();
    }

    public function created(Post $post): void
    {
        Cache::tags('posts')->flush();
    }

    public function updated(Post $post): void
    {
        Cache::tags('posts')->flush();
    }

    public function deleted(Post $post): void
    {
        $post->comments()->delete();
    }
}

// Register in AppServiceProvider::boot()
Post::observe(PostObserver::class);

// Silence observer for bulk operations
Post::withoutObservers(function () {
    Post::query()->update(['featured' => false]);
});
```

---

## Soft Deletes

```php
use Illuminate\Database\Eloquent\SoftDeletes;

class Post extends Model
{
    use SoftDeletes; // adds deleted_at column
}

// Migration
Schema::table('posts', function (Blueprint $table) {
    $table->softDeletes(); // nullable deleted_at timestamp
});

// Usage
$post->delete();           // sets deleted_at (soft delete)
$post->forceDelete();      // permanent DELETE

// Querying
Post::all();               // excludes soft-deleted (default)
Post::withTrashed()->get(); // includes soft-deleted
Post::onlyTrashed()->get(); // only soft-deleted

// Restore
Post::withTrashed()->find($id)->restore();
Post::withTrashed()->where('user_id', $userId)->restore();

// Check state
$post->trashed();          // bool

// Route model binding includes soft-deleted
Route::get('/posts/{post}', [PostController::class, 'show'])
    ->withTrashed();
```

---

## Pagination

| Method | Returns | Use When |
|--------|---------|----------|
| `paginate(15)` | `LengthAwarePaginator` | Need total count and last page |
| `simplePaginate(15)` | `Paginator` | Large datasets, just next/prev needed |
| `cursorPaginate(15)` | `CursorPaginator` | Huge datasets, consistent performance |

```php
// Standard pagination (requires COUNT query)
$posts = Post::published()->paginate(15);
// Blade: {{ $posts->links() }}

// Simple pagination (no COUNT, just LIMIT+1)
$posts = Post::published()->simplePaginate(15);

// Cursor pagination (keyset pagination - best for infinite scroll)
$posts = Post::orderBy('id')->cursorPaginate(15);
// URL: /posts?cursor=eyJpZCI6MTAwfQ

// JSON API response
return PostResource::collection($posts); // preserves pagination meta

// Manual pagination
$total = Post::count();
$posts = Post::skip($offset)->take($perPage)->get();
$paginator = new LengthAwarePaginator($posts, $total, $perPage, $currentPage);
```

---

## Performance: Chunking and Lazy Loading

### When to Use Each

| Method | Memory | Speed | Use When |
|--------|--------|-------|----------|
| `get()` | All records | Fast | < 10k records |
| `chunk(1000)` | Chunk size | Moderate | Large datasets, mutations |
| `chunkById(1000)` | Chunk size | More stable | Large datasets (avoids offset drift) |
| `lazy()` | Low (generator) | Fast | Read-only iteration |
| `cursor()` | Very low | Fastest | Streaming large result sets |

```php
// chunk - runs separate queries per chunk
Post::where('status', 'draft')->chunk(500, function (Collection $posts) {
    foreach ($posts as $post) {
        $post->update(['status' => 'published']);
    }
});

// chunkById - stable cursor-based chunking (avoids missing rows when deleting)
Post::orderBy('id')->chunkById(500, function (Collection $posts) {
    $posts->each->delete();
});

// lazy - PHP generator, single query with cursor
foreach (Post::lazy(500) as $post) {
    ProcessPost::dispatch($post);
}

// cursor - yields one model at a time, minimal memory
foreach (Post::cursor() as $post) {
    echo $post->title . PHP_EOL;
}
```

### Query Logging and Debugging

```php
// Log all queries (AppServiceProvider::boot)
DB::listen(function (QueryExecuted $query) {
    Log::channel('queries')->info($query->sql, [
        'bindings' => $query->bindings,
        'time'     => $query->time,
    ]);
});

// Explain a query
$posts = Post::with('comments')->where('status', 'published');
dd($posts->explain()); // EXPLAIN output

// Count queries executed (testing)
DB::enableQueryLog();
// ... run code ...
$queries = DB::getQueryLog();
expect($queries)->toHaveCount(2); // assert no N+1
DB::disableQueryLog();

// Prevent lazy loading in development
Model::preventLazyLoading(! app()->isProduction());
```

---

## Collections

Eloquent returns `Illuminate\Database\Eloquent\Collection` (extends base Collection).

```php
$users = User::all();

// Transformation
$names      = $users->pluck('name');                    // Collection of names
$names      = $users->pluck('name', 'id');              // ['id' => 'name'] keyed
$active     = $users->filter(fn($u) => $u->is_active);
$admins     = $users->where('role', 'admin');
$mapped     = $users->map(fn($u) => ['id' => $u->id, 'email' => $u->email]);
$grouped    = $users->groupBy('country');               // keyed Collection of Collections
$sorted     = $users->sortBy('name');
$sorted     = $users->sortByDesc(fn($u) => $u->posts_count);

// Aggregation
$total      = $users->sum('balance');
$avg        = $users->avg('score');
$max        = $users->max('score');
$count      = $users->count();
$first      = $users->first(fn($u) => $u->is_admin);

// Unique / diff / intersect
$unique     = $users->unique('email');
$diff       = $users->diff($otherUsers);

// Collection to array/JSON
$array      = $users->toArray();
$json       = $users->toJson();

// Reduce
$total = $users->reduce(fn($carry, $user) => $carry + $user->balance, 0);

// Eloquent-specific collection methods
$users->find(1);                                        // find by PK
$users->load('posts');                                  // eager load on collection
$users->modelKeys();                                    // array of primary keys
$users->contains($user);                                // check membership
$users->diff($otherUsers);                              // by PK comparison

// Lazy collections (memory efficient)
User::lazy()->filter(fn($u) => $u->is_active)->each(fn($u) => ProcessUser::dispatch($u));
```

---

## Factories

```php
// database/factories/PostFactory.php
class PostFactory extends Factory
{
    protected $model = Post::class;

    public function definition(): array
    {
        return [
            'user_id'      => User::factory(),         // auto-create related
            'title'        => $this->faker->sentence(),
            'slug'         => $this->faker->unique()->slug(),
            'body'         => $this->faker->paragraphs(3, true),
            'status'       => 'published',
            'published_at' => $this->faker->dateTimeBetween('-1 year'),
        ];
    }

    // States - modifiers
    public function draft(): static
    {
        return $this->state(['status' => 'draft', 'published_at' => null]);
    }

    public function featured(): static
    {
        return $this->state(['status' => 'featured']);
    }

    public function withTags(int $count = 3): static
    {
        return $this->afterCreating(function (Post $post) use ($count) {
            $post->tags()->attach(Tag::factory()->count($count)->create());
        });
    }

    // Sequence - vary per-record
    public function configure(): static
    {
        return $this->sequence(
            ['status' => 'draft'],
            ['status' => 'published'],
            ['status' => 'archived'],
        );
    }
}

// Usage in tests or seeders
Post::factory()->create();                              // single
Post::factory()->count(10)->create();                   // 10 records
Post::factory()->draft()->create();                     // apply state
Post::factory()->featured()->withTags(5)->create();     // chain states
Post::factory()->for(User::factory()->admin())->create(); // explicit relationship
Post::factory()->has(Comment::factory()->count(3))->create(); // hasMany
Post::factory()->hasComments(3)->create();              // magic has method

// In-memory (not persisted)
Post::factory()->make();
Post::factory()->makeMany(5);

// Sequences
Post::factory()->count(3)->sequence(
    ['status' => 'draft'],
    ['status' => 'published'],
    ['status' => 'archived'],
)->create();

// afterCreating callback
Post::factory()->afterCreating(function (Post $post) {
    $post->searchIndex()->create(['content' => $post->body]);
})->create();
```

---

## Advanced Patterns

### Subquery Selects for Aggregates (avoid N+1)

```php
// Instead of: $users->each(fn($u) => $u->posts->count())
// Do this:
$users = User::addSelect([
    'posts_count' => Post::selectRaw('COUNT(*)')
        ->whereColumn('user_id', 'users.id'),
    'last_post_at' => Post::select('created_at')
        ->whereColumn('user_id', 'users.id')
        ->latest()
        ->limit(1),
])->get();
```

### Upsert

```php
// Single upsert
User::updateOrCreate(
    ['email' => 'user@example.com'],             // find by
    ['name' => 'John', 'role' => 'admin']        // update/create with
);

// Bulk upsert (one query)
Post::upsert(
    [
        ['id' => 1, 'title' => 'Updated', 'slug' => 'updated'],
        ['id' => 2, 'title' => 'New Post', 'slug' => 'new-post'],
    ],
    uniqueBy: ['slug'],                          // conflict column(s)
    update: ['title']                            // columns to update on conflict
);
```

### Locking for Concurrency

```php
// Shared lock (read lock - prevent other writes)
$order = Order::where('id', $id)->sharedLock()->first();

// Exclusive lock (write lock - prevent other reads and writes)
DB::transaction(function () use ($orderId) {
    $order = Order::where('id', $orderId)->lockForUpdate()->first();
    $order->decrement('quantity');
});
```
