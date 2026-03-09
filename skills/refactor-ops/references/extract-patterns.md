# Extract Patterns Reference

Detailed patterns for extracting code into well-named, well-scoped units. Each pattern includes when to apply, when NOT to apply, before/after examples in multiple languages, and common mistakes.

---

## Extract Function / Method

### When to Apply

- A block of code has a clear, nameable purpose
- The same logic appears in multiple places
- A function is too long and has identifiable sub-tasks
- A comment explains what the next block does (the comment becomes the function name)
- You want to test a piece of logic independently

### When NOT to Apply

- The code is already short and clear (1-3 lines with obvious intent)
- Extracting would require passing 5+ parameters (refactor coupling first)
- The code relies heavily on local mutable state that is hard to pass around
- The "extracted" function would only be called once and adds no clarity

### Parameter Design

```
How many inputs does the extracted code need?
│
├─ 0-3 values → Pass as individual parameters
│
├─ 4+ related values → Group into a parameter object / struct
│  └─ { user, permissions, settings } instead of (user, perms, theme, lang, tz)
│
├─ Values come from a shared context → Consider making it a method on that context
│
└─ Mix of config and data → Separate: config as constructor/init, data as method params
```

### Naming Guidelines

- Name describes WHAT, not HOW: `calculateShippingCost` not `loopThroughItemsAndSum`
- Use verbs for actions: `validate`, `transform`, `calculate`, `fetch`, `build`
- Use predicates for booleans: `isValid`, `hasPermission`, `canAccess`, `shouldRetry`
- Avoid generic names: `process`, `handle`, `do`, `run`, `execute` (too vague alone)
- Include the domain noun: `validateEmail` not just `validate`

### JavaScript / TypeScript

**Before:**

```typescript
async function processOrder(order: Order) {
  // Validate order items
  if (order.items.length === 0) {
    throw new Error('Order must have at least one item');
  }
  for (const item of order.items) {
    if (item.quantity <= 0) {
      throw new Error(`Invalid quantity for item ${item.id}`);
    }
    if (item.price < 0) {
      throw new Error(`Invalid price for item ${item.id}`);
    }
  }

  // Calculate totals
  let subtotal = 0;
  for (const item of order.items) {
    subtotal += item.price * item.quantity;
  }
  const tax = subtotal * 0.08;
  const shipping = subtotal > 100 ? 0 : 9.99;
  const total = subtotal + tax + shipping;

  // Persist
  const savedOrder = await db.orders.create({
    ...order,
    subtotal,
    tax,
    shipping,
    total,
    status: 'confirmed',
  });

  // Notify
  await emailService.send(order.customerEmail, 'Order Confirmed', {
    orderId: savedOrder.id,
    total,
  });

  return savedOrder;
}
```

**After:**

```typescript
async function processOrder(order: Order): Promise<SavedOrder> {
  validateOrderItems(order.items);
  const totals = calculateOrderTotals(order.items);
  const savedOrder = await persistOrder(order, totals);
  await notifyCustomer(order.customerEmail, savedOrder.id, totals.total);
  return savedOrder;
}

function validateOrderItems(items: OrderItem[]): void {
  if (items.length === 0) {
    throw new Error('Order must have at least one item');
  }
  for (const item of items) {
    if (item.quantity <= 0) {
      throw new Error(`Invalid quantity for item ${item.id}`);
    }
    if (item.price < 0) {
      throw new Error(`Invalid price for item ${item.id}`);
    }
  }
}

interface OrderTotals {
  subtotal: number;
  tax: number;
  shipping: number;
  total: number;
}

function calculateOrderTotals(items: OrderItem[]): OrderTotals {
  const subtotal = items.reduce((sum, item) => sum + item.price * item.quantity, 0);
  const tax = subtotal * TAX_RATE;
  const shipping = subtotal > FREE_SHIPPING_THRESHOLD ? 0 : SHIPPING_COST;
  const total = subtotal + tax + shipping;
  return { subtotal, tax, shipping, total };
}

async function persistOrder(order: Order, totals: OrderTotals): Promise<SavedOrder> {
  return db.orders.create({ ...order, ...totals, status: 'confirmed' });
}

async function notifyCustomer(email: string, orderId: string, total: number): Promise<void> {
  await emailService.send(email, 'Order Confirmed', { orderId, total });
}
```

### Python

**Before:**

```python
def generate_report(users, start_date, end_date):
    # Filter active users in date range
    active_users = []
    for user in users:
        if user.is_active and start_date <= user.created_at <= end_date:
            if user.email_verified:
                active_users.append(user)

    # Calculate statistics
    total_revenue = 0
    for user in active_users:
        for order in user.orders:
            if order.status == "completed":
                total_revenue += order.total

    avg_revenue = total_revenue / len(active_users) if active_users else 0

    # Format output
    lines = [f"Report: {start_date} to {end_date}"]
    lines.append(f"Active Users: {len(active_users)}")
    lines.append(f"Total Revenue: ${total_revenue:.2f}")
    lines.append(f"Avg Revenue/User: ${avg_revenue:.2f}")
    return "\n".join(lines)
```

**After:**

```python
def generate_report(users: list[User], start_date: date, end_date: date) -> str:
    active_users = filter_active_users(users, start_date, end_date)
    revenue = calculate_total_revenue(active_users)
    avg_revenue = revenue / len(active_users) if active_users else 0
    return format_report(start_date, end_date, len(active_users), revenue, avg_revenue)


def filter_active_users(users: list[User], start: date, end: date) -> list[User]:
    return [
        u for u in users
        if u.is_active and u.email_verified and start <= u.created_at <= end
    ]


def calculate_total_revenue(users: list[User]) -> float:
    return sum(
        order.total
        for user in users
        for order in user.orders
        if order.status == "completed"
    )


def format_report(start: date, end: date, user_count: int, revenue: float, avg: float) -> str:
    return "\n".join([
        f"Report: {start} to {end}",
        f"Active Users: {user_count}",
        f"Total Revenue: ${revenue:.2f}",
        f"Avg Revenue/User: ${avg:.2f}",
    ])
```

### Go

**Before:**

```go
func HandleUpload(w http.ResponseWriter, r *http.Request) {
    file, header, err := r.FormFile("document")
    if err != nil {
        http.Error(w, "Failed to read file", http.StatusBadRequest)
        return
    }
    defer file.Close()

    if header.Size > 10*1024*1024 {
        http.Error(w, "File too large", http.StatusBadRequest)
        return
    }
    ext := filepath.Ext(header.Filename)
    if ext != ".pdf" && ext != ".docx" && ext != ".txt" {
        http.Error(w, "Unsupported file type", http.StatusBadRequest)
        return
    }

    data, err := io.ReadAll(file)
    if err != nil {
        http.Error(w, "Failed to read file", http.StatusInternalServerError)
        return
    }

    hash := sha256.Sum256(data)
    filename := fmt.Sprintf("%x%s", hash, ext)
    path := filepath.Join("uploads", filename)
    if err := os.WriteFile(path, data, 0644); err != nil {
        http.Error(w, "Failed to save file", http.StatusInternalServerError)
        return
    }

    json.NewEncoder(w).Encode(map[string]string{"path": path})
}
```

**After:**

```go
func HandleUpload(w http.ResponseWriter, r *http.Request) {
    file, header, err := r.FormFile("document")
    if err != nil {
        http.Error(w, "Failed to read file", http.StatusBadRequest)
        return
    }
    defer file.Close()

    if err := validateUpload(header); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }

    path, err := saveFile(file, header.Filename)
    if err != nil {
        http.Error(w, "Failed to save file", http.StatusInternalServerError)
        return
    }

    json.NewEncoder(w).Encode(map[string]string{"path": path})
}

func validateUpload(header *multipart.FileHeader) error {
    if header.Size > maxUploadSize {
        return fmt.Errorf("file too large (max %d bytes)", maxUploadSize)
    }
    ext := filepath.Ext(header.Filename)
    if !allowedExtensions[ext] {
        return fmt.Errorf("unsupported file type: %s", ext)
    }
    return nil
}

func saveFile(file multipart.File, originalName string) (string, error) {
    data, err := io.ReadAll(file)
    if err != nil {
        return "", fmt.Errorf("reading file: %w", err)
    }
    hash := sha256.Sum256(data)
    ext := filepath.Ext(originalName)
    filename := fmt.Sprintf("%x%s", hash, ext)
    path := filepath.Join("uploads", filename)
    if err := os.WriteFile(path, data, 0644); err != nil {
        return "", fmt.Errorf("writing file: %w", err)
    }
    return path, nil
}
```

### Rust

**Before:**

```rust
fn process_csv(path: &str) -> Result<Vec<Record>, Box<dyn Error>> {
    let content = fs::read_to_string(path)?;
    let mut records = Vec::new();

    for (i, line) in content.lines().enumerate() {
        if i == 0 { continue; } // skip header
        let fields: Vec<&str> = line.split(',').collect();
        if fields.len() < 3 {
            eprintln!("Skipping malformed line {}: {}", i, line);
            continue;
        }
        let name = fields[0].trim().to_string();
        let age: u32 = match fields[1].trim().parse() {
            Ok(a) if a > 0 && a < 150 => a,
            _ => {
                eprintln!("Invalid age on line {}", i);
                continue;
            }
        };
        let email = fields[2].trim().to_string();
        if !email.contains('@') {
            eprintln!("Invalid email on line {}", i);
            continue;
        }
        records.push(Record { name, age, email });
    }
    Ok(records)
}
```

**After:**

```rust
fn process_csv(path: &str) -> Result<Vec<Record>, Box<dyn Error>> {
    let content = fs::read_to_string(path)?;
    let records = content
        .lines()
        .enumerate()
        .skip(1) // skip header
        .filter_map(|(i, line)| parse_record(i, line))
        .collect();
    Ok(records)
}

fn parse_record(line_num: usize, line: &str) -> Option<Record> {
    let fields: Vec<&str> = line.split(',').collect();
    if fields.len() < 3 {
        eprintln!("Skipping malformed line {}: {}", line_num, line);
        return None;
    }
    let name = fields[0].trim().to_string();
    let age = parse_age(fields[1].trim(), line_num)?;
    let email = parse_email(fields[2].trim(), line_num)?;
    Some(Record { name, age, email })
}

fn parse_age(s: &str, line_num: usize) -> Option<u32> {
    match s.parse::<u32>() {
        Ok(a) if a > 0 && a < 150 => Some(a),
        _ => {
            eprintln!("Invalid age on line {}", line_num);
            None
        }
    }
}

fn parse_email(s: &str, line_num: usize) -> Option<String> {
    if s.contains('@') {
        Some(s.to_string())
    } else {
        eprintln!("Invalid email on line {}", line_num);
        None
    }
}
```

### Common Mistakes

| Mistake | Problem | Fix |
|---------|---------|-----|
| Extracting with too many parameters | Function signature is unwieldy, hard to call | Group related params into a struct/object first |
| Naming the function after its implementation | `loopAndFilter` tells you nothing useful | Name after the WHAT: `filterActiveUsers` |
| Extracting one line into a function | Adds indirection without clarity | Only extract if the name adds understanding |
| Not returning a value | Using mutation/side effects when a return value is cleaner | Prefer pure functions that return results |
| Leaving the original code commented out | Clutters the file, confuses future readers | Delete it; git has history |

---

## Extract Component

### When to Apply

- A section of UI has its own state or lifecycle
- The same UI pattern appears in multiple places
- A component file exceeds 200 lines
- A piece of UI has a clear responsibility boundary
- You want to test UI logic independently

### When NOT to Apply

- The UI is a one-off, simple, and under 30 lines
- Extracting would require 10+ props (the component boundary is wrong)
- The "component" has no reuse potential and splitting hurts readability

### React

**Before:**

```tsx
function Dashboard({ user }: { user: User }) {
  const [searchTerm, setSearchTerm] = useState('');
  const [sortBy, setSortBy] = useState<'name' | 'date'>('date');

  const filteredProjects = useMemo(() => {
    return user.projects
      .filter(p => p.name.toLowerCase().includes(searchTerm.toLowerCase()))
      .sort((a, b) => sortBy === 'name'
        ? a.name.localeCompare(b.name)
        : b.createdAt.getTime() - a.createdAt.getTime()
      );
  }, [user.projects, searchTerm, sortBy]);

  return (
    <div>
      <h1>Welcome, {user.name}</h1>
      <div>
        <input
          value={searchTerm}
          onChange={e => setSearchTerm(e.target.value)}
          placeholder="Search projects..."
        />
        <select value={sortBy} onChange={e => setSortBy(e.target.value as 'name' | 'date')}>
          <option value="date">Sort by Date</option>
          <option value="name">Sort by Name</option>
        </select>
      </div>
      <ul>
        {filteredProjects.map(project => (
          <li key={project.id}>
            <h3>{project.name}</h3>
            <p>{project.description}</p>
            <span>{project.createdAt.toLocaleDateString()}</span>
            <span>{project.status}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
```

**After:**

```tsx
function Dashboard({ user }: { user: User }) {
  return (
    <div>
      <h1>Welcome, {user.name}</h1>
      <ProjectList projects={user.projects} />
    </div>
  );
}

// --- project-list.tsx ---

function ProjectList({ projects }: { projects: Project[] }) {
  const [searchTerm, setSearchTerm] = useState('');
  const [sortBy, setSortBy] = useState<SortField>('date');

  const filteredProjects = useFilteredProjects(projects, searchTerm, sortBy);

  return (
    <div>
      <ProjectFilters
        searchTerm={searchTerm}
        onSearchChange={setSearchTerm}
        sortBy={sortBy}
        onSortChange={setSortBy}
      />
      <ul>
        {filteredProjects.map(project => (
          <ProjectCard key={project.id} project={project} />
        ))}
      </ul>
    </div>
  );
}

// --- project-card.tsx ---

function ProjectCard({ project }: { project: Project }) {
  return (
    <li>
      <h3>{project.name}</h3>
      <p>{project.description}</p>
      <span>{project.createdAt.toLocaleDateString()}</span>
      <span>{project.status}</span>
    </li>
  );
}
```

### Vue

**Before:**

```vue
<template>
  <div>
    <input v-model="search" placeholder="Search..." />
    <ul>
      <li v-for="item in filteredItems" :key="item.id">
        <h3>{{ item.title }}</h3>
        <p>{{ item.body }}</p>
        <button @click="toggleFavorite(item.id)">
          {{ item.isFavorite ? 'Unfavorite' : 'Favorite' }}
        </button>
      </li>
    </ul>
  </div>
</template>
```

**After:**

```vue
<!-- SearchableList.vue -->
<template>
  <div>
    <SearchInput v-model="search" />
    <ItemCard
      v-for="item in filteredItems"
      :key="item.id"
      :item="item"
      @toggle-favorite="toggleFavorite"
    />
  </div>
</template>

<!-- ItemCard.vue -->
<template>
  <li>
    <h3>{{ item.title }}</h3>
    <p>{{ item.body }}</p>
    <button @click="$emit('toggle-favorite', item.id)">
      {{ item.isFavorite ? 'Unfavorite' : 'Favorite' }}
    </button>
  </li>
</template>
```

### Extraction Boundaries Decision

```
Should this be its own component?
│
├─ Does it have its own state? → YES, extract
├─ Is it reused in 2+ places? → YES, extract
├─ Is it > 50 lines of JSX/template? → Probably, extract
├─ Does it have a clear domain name? → YES, extract
├─ Would extracting require > 8 props? → NO, fix the boundary first
└─ Is it pure presentation, < 20 lines? → Probably not worth it
```

---

## Extract Hook / Composable

### When to Apply

- Stateful logic is duplicated across components
- A component has complex state management obscuring the template/JSX
- You want to test stateful logic without rendering
- The logic is reusable across different UI presentations

### When NOT to Apply

- The logic is simple and only used in one component
- The hook would just wrap a single useState/useRef with no additional logic
- The hook needs access to the component's render context

### React Custom Hook

**Before:**

```tsx
function UserProfile({ userId }: { userId: string }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    setError(null);

    fetchUser(userId, { signal: controller.signal })
      .then(setUser)
      .catch(err => {
        if (!controller.signal.aborted) setError(err);
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false);
      });

    return () => controller.abort();
  }, [userId]);

  if (loading) return <Spinner />;
  if (error) return <ErrorMessage error={error} />;
  if (!user) return null;

  return <div>{user.name}</div>;
}
```

**After:**

```tsx
// hooks/use-user.ts
function useUser(userId: string) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    setError(null);

    fetchUser(userId, { signal: controller.signal })
      .then(setUser)
      .catch(err => {
        if (!controller.signal.aborted) setError(err);
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false);
      });

    return () => controller.abort();
  }, [userId]);

  return { user, loading, error };
}

// components/user-profile.tsx
function UserProfile({ userId }: { userId: string }) {
  const { user, loading, error } = useUser(userId);

  if (loading) return <Spinner />;
  if (error) return <ErrorMessage error={error} />;
  if (!user) return null;

  return <div>{user.name}</div>;
}
```

### Vue Composable

**Before:**

```vue
<script setup>
const items = ref([]);
const loading = ref(false);
const page = ref(1);
const hasMore = ref(true);

async function loadMore() {
  if (loading.value || !hasMore.value) return;
  loading.value = true;
  try {
    const result = await fetchItems({ page: page.value });
    items.value.push(...result.data);
    hasMore.value = result.hasMore;
    page.value++;
  } finally {
    loading.value = false;
  }
}

onMounted(loadMore);
</script>
```

**After:**

```typescript
// composables/use-paginated-list.ts
export function usePaginatedList<T>(fetcher: (page: number) => Promise<{ data: T[]; hasMore: boolean }>) {
  const items = ref<T[]>([]);
  const loading = ref(false);
  const page = ref(1);
  const hasMore = ref(true);

  async function loadMore() {
    if (loading.value || !hasMore.value) return;
    loading.value = true;
    try {
      const result = await fetcher(page.value);
      items.value.push(...result.data);
      hasMore.value = result.hasMore;
      page.value++;
    } finally {
      loading.value = false;
    }
  }

  onMounted(loadMore);

  return { items, loading, hasMore, loadMore };
}
```

```vue
<script setup>
const { items, loading, hasMore, loadMore } = usePaginatedList(
  (page) => fetchItems({ page })
);
</script>
```

---

## Extract Module

### When to Apply

- A file exceeds 300-500 lines
- A file contains multiple unrelated classes or groups of functions
- You want to lazy-load part of a file
- Testing requires importing the whole file when you only need a part

### When NOT to Apply

- The file is long but cohesive (one responsibility, everything interdependent)
- Splitting would create circular dependencies
- The file is generated code

### Strategy

```
Large File (500+ lines)
│
├─ Identify responsibility clusters
│  Group functions/classes by what they operate on
│
├─ Check dependency direction
│  Draw arrows: A uses B means A depends on B
│  If A and B depend on each other → shared types module first
│
├─ Create new files, one per cluster
│  Each file exports its public API
│
├─ Create barrel file (index.ts) if needed
│  Re-export public API for backward compatibility
│
└─ Update imports across codebase
   One file at a time, running tests after each
```

### Before (single large file):

```typescript
// utils.ts (600 lines)
export function formatDate(d: Date): string { /* ... */ }
export function parseDate(s: string): Date { /* ... */ }
export function daysBetween(a: Date, b: Date): number { /* ... */ }

export function formatCurrency(amount: number, currency: string): string { /* ... */ }
export function parseCurrency(s: string): number { /* ... */ }
export function convertCurrency(amount: number, from: string, to: string): number { /* ... */ }

export function validateEmail(email: string): boolean { /* ... */ }
export function validatePhone(phone: string): boolean { /* ... */ }
export function validateUrl(url: string): boolean { /* ... */ }
```

### After (split by responsibility):

```typescript
// utils/date.ts
export function formatDate(d: Date): string { /* ... */ }
export function parseDate(s: string): Date { /* ... */ }
export function daysBetween(a: Date, b: Date): number { /* ... */ }

// utils/currency.ts
export function formatCurrency(amount: number, currency: string): string { /* ... */ }
export function parseCurrency(s: string): number { /* ... */ }
export function convertCurrency(amount: number, from: string, to: string): number { /* ... */ }

// utils/validation.ts
export function validateEmail(email: string): boolean { /* ... */ }
export function validatePhone(phone: string): boolean { /* ... */ }
export function validateUrl(url: string): boolean { /* ... */ }

// utils/index.ts (barrel - backward compatible)
export * from './date';
export * from './currency';
export * from './validation';
```

### Circular Dependency Resolution

```
Problem: A imports from B, B imports from A

Solution 1: Extract shared types
├─ types.ts (shared interfaces/types)
├─ a.ts (imports from types.ts)
└─ b.ts (imports from types.ts)

Solution 2: Dependency inversion
├─ a.ts (defines interface, imports nothing from B)
├─ b.ts (implements A's interface)
└─ main.ts (wires A and B together)

Solution 3: Merge if truly coupled
└─ ab.ts (if A and B are one responsibility, keep them together)
```

---

## Extract Class / Service

### When to Apply

- A class has more than one reason to change (SRP violation)
- A group of functions all operate on the same data
- You need to swap implementations (strategy pattern, testing)
- Business logic is mixed with infrastructure (DB, HTTP, file I/O)

### When NOT to Apply

- The class is already cohesive and under 200 lines
- Extracting would create classes with only one method
- The "class" is really just a namespace for utility functions (use a module instead)

### TypeScript

**Before:**

```typescript
class OrderService {
  async createOrder(items: CartItem[], customer: Customer): Promise<Order> {
    // Validation
    if (items.length === 0) throw new Error('Cart is empty');
    for (const item of items) {
      const product = await this.db.products.findById(item.productId);
      if (!product) throw new Error(`Product ${item.productId} not found`);
      if (product.stock < item.quantity) throw new Error(`Insufficient stock`);
    }

    // Price calculation
    let subtotal = 0;
    for (const item of items) {
      const product = await this.db.products.findById(item.productId);
      subtotal += product!.price * item.quantity;
    }
    const discount = customer.tier === 'premium' ? subtotal * 0.1 : 0;
    const tax = (subtotal - discount) * 0.08;
    const total = subtotal - discount + tax;

    // Persistence
    const order = await this.db.orders.create({ items, customerId: customer.id, subtotal, discount, tax, total });

    // Notification
    await this.mailer.send(customer.email, 'Order Confirmed', { orderId: order.id, total });
    if (total > 500) {
      await this.slack.notify('#high-value-orders', `New order: $${total}`);
    }

    return order;
  }
}
```

**After:**

```typescript
class OrderService {
  constructor(
    private validator: OrderValidator,
    private calculator: PriceCalculator,
    private repository: OrderRepository,
    private notifier: OrderNotifier,
  ) {}

  async createOrder(items: CartItem[], customer: Customer): Promise<Order> {
    await this.validator.validateItems(items);
    const pricing = this.calculator.calculate(items, customer);
    const order = await this.repository.save(items, customer, pricing);
    await this.notifier.orderConfirmed(order, customer);
    return order;
  }
}

class OrderValidator {
  constructor(private productRepo: ProductRepository) {}

  async validateItems(items: CartItem[]): Promise<void> {
    if (items.length === 0) throw new Error('Cart is empty');
    for (const item of items) {
      const product = await this.productRepo.findById(item.productId);
      if (!product) throw new Error(`Product ${item.productId} not found`);
      if (product.stock < item.quantity) throw new Error('Insufficient stock');
    }
  }
}

class PriceCalculator {
  calculate(items: CartItem[], customer: Customer): OrderPricing {
    const subtotal = items.reduce((sum, i) => sum + i.price * i.quantity, 0);
    const discount = customer.tier === 'premium' ? subtotal * 0.1 : 0;
    const tax = (subtotal - discount) * TAX_RATE;
    return { subtotal, discount, tax, total: subtotal - discount + tax };
  }
}
```

### Python

**Before:**

```python
class ReportGenerator:
    def generate(self, data, format_type, output_path):
        # Data processing
        cleaned = [row for row in data if row.get("valid")]
        grouped = {}
        for row in cleaned:
            key = row["category"]
            grouped.setdefault(key, []).append(row)

        # Aggregation
        summary = {}
        for cat, rows in grouped.items():
            summary[cat] = {
                "count": len(rows),
                "total": sum(r["amount"] for r in rows),
                "average": sum(r["amount"] for r in rows) / len(rows),
            }

        # Formatting
        if format_type == "csv":
            output = self._to_csv(summary)
        elif format_type == "json":
            output = json.dumps(summary, indent=2)
        elif format_type == "html":
            output = self._to_html(summary)

        # File I/O
        with open(output_path, "w") as f:
            f.write(output)
```

**After:**

```python
class ReportGenerator:
    def __init__(self, processor: DataProcessor, formatter: ReportFormatter, writer: FileWriter):
        self.processor = processor
        self.formatter = formatter
        self.writer = writer

    def generate(self, data: list[dict], format_type: str, output_path: str) -> None:
        summary = self.processor.summarize(data)
        output = self.formatter.format(summary, format_type)
        self.writer.write(output, output_path)


class DataProcessor:
    def summarize(self, data: list[dict]) -> dict[str, CategorySummary]:
        cleaned = [row for row in data if row.get("valid")]
        grouped = self._group_by_category(cleaned)
        return {cat: self._aggregate(rows) for cat, rows in grouped.items()}

    def _group_by_category(self, rows):
        grouped = {}
        for row in rows:
            grouped.setdefault(row["category"], []).append(row)
        return grouped

    def _aggregate(self, rows):
        amounts = [r["amount"] for r in rows]
        return CategorySummary(count=len(rows), total=sum(amounts), average=sum(amounts) / len(rows))
```

---

## Extract Configuration

### When to Apply

- Magic numbers or strings scattered through code
- Environment-specific values hardcoded (URLs, ports, timeouts)
- Feature flags or A/B test conditions inline
- Same constants defined in multiple files

### When NOT to Apply

- The value is truly constant and universal (pi = 3.14159)
- The value is used exactly once and is self-documenting in context
- Extracting would require a complex configuration system for 2-3 values

### Before:

```typescript
async function fetchWithRetry(url: string) {
  for (let i = 0; i < 3; i++) {
    try {
      const response = await fetch(url, { timeout: 5000 });
      if (response.status === 429) {
        await sleep(1000 * Math.pow(2, i));
        continue;
      }
      return response;
    } catch {
      if (i === 2) throw new Error('Max retries exceeded');
      await sleep(1000 * Math.pow(2, i));
    }
  }
}
```

### After:

```typescript
// config/retry.ts
export const RETRY_CONFIG = {
  maxAttempts: 3,
  baseDelayMs: 1000,
  requestTimeoutMs: 5000,
  backoffMultiplier: 2,
  retryableStatusCodes: [429, 502, 503, 504],
} as const;

// lib/fetch-with-retry.ts
import { RETRY_CONFIG } from '../config/retry';

async function fetchWithRetry(url: string, config = RETRY_CONFIG) {
  for (let attempt = 0; attempt < config.maxAttempts; attempt++) {
    try {
      const response = await fetch(url, { timeout: config.requestTimeoutMs });
      if (config.retryableStatusCodes.includes(response.status)) {
        await sleep(config.baseDelayMs * Math.pow(config.backoffMultiplier, attempt));
        continue;
      }
      return response;
    } catch {
      if (attempt === config.maxAttempts - 1) throw new Error('Max retries exceeded');
      await sleep(config.baseDelayMs * Math.pow(config.backoffMultiplier, attempt));
    }
  }
}
```

### Configuration Extraction Checklist

```
[ ] Identified all magic numbers and strings
[ ] Grouped related config values into typed objects
[ ] Added sensible defaults (don't require config for common case)
[ ] Made config injectable for testing (parameter with default)
[ ] Documented units in names (timeoutMs, maxRetries, limitBytes)
[ ] Used const assertions or enums for type safety
[ ] Kept environment-specific values in env vars, not code
```
