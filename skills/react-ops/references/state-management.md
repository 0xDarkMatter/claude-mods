# State Management

Comprehensive reference for React state: Context API, Zustand, Jotai, Redux Toolkit, TanStack Query, React Hook Form, and URL state.

---

## Decision Matrix

| State Type | Scope | Change Freq | Best Tool |
|------------|-------|-------------|-----------|
| Local UI (toggle, form input) | Component | Any | `useState` / `useReducer` |
| Shared, rarely changes (theme, locale, auth) | App-wide | Low | Context API |
| Global client state (cart, UI prefs) | App-wide | Medium-High | Zustand |
| Atomic/fine-grained state | App-wide | High | Jotai |
| Complex flows, large team, time-travel debug | App-wide | Any | Redux Toolkit |
| Server data (API responses, cache) | App-wide | External | TanStack Query |
| Form state | Component | High | React Hook Form |
| URL-driven state (filters, pagination) | Shareable | Medium | `useSearchParams` / nuqs |

---

## Context API

### Basic Pattern

```tsx
import { createContext, useContext, useState, useMemo, ReactNode } from 'react';

interface ThemeContextValue {
  theme: 'light' | 'dark';
  toggleTheme: () => void;
}

// 1. Create context with null default (enforces provider requirement)
const ThemeContext = createContext<ThemeContextValue | null>(null);

// 2. Custom hook — single usage point, enforces provider
export function useTheme(): ThemeContextValue {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error('useTheme must be used within ThemeProvider');
  return ctx;
}

// 3. Provider — memoize value to prevent unnecessary consumer re-renders
export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useState<'light' | 'dark'>('light');

  // Memoize so object reference only changes when theme changes
  const value = useMemo(
    () => ({ theme, toggleTheme: () => setTheme(t => (t === 'light' ? 'dark' : 'light')) }),
    [theme]
  );

  return (
    <ThemeContext.Provider value={value}>
      {children}
    </ThemeContext.Provider>
  );
}
```

### Performance: Split Contexts by Update Frequency

```tsx
// BAD: single context — every consumer re-renders when ANY value changes
const AppContext = createContext({ user, cart, theme, notifications });

// GOOD: separate contexts — consumers only re-render for what they use
const UserContext = createContext<User | null>(null);
const CartContext = createContext<CartState | null>(null);
const ThemeContext = createContext<Theme>('light');

// BAD: context value recreated every render
function BadProvider({ children }: { children: ReactNode }) {
  const [count, setCount] = useState(0);
  return (
    // New object reference every render — all consumers re-render!
    <MyContext.Provider value={{ count, setCount }}>
      {children}
    </MyContext.Provider>
  );
}

// GOOD: memoized value
function GoodProvider({ children }: { children: ReactNode }) {
  const [count, setCount] = useState(0);
  const value = useMemo(() => ({ count, setCount }), [count]);
  return <MyContext.Provider value={value}>{children}</MyContext.Provider>;
}
```

---

## Zustand

Minimal boilerplate, no providers needed, supports middleware.

### Basic Store

```typescript
import { create } from 'zustand';
import { devtools, persist } from 'zustand/middleware';

interface BearState {
  bears: number;
  increase: (by?: number) => void;
  reset: () => void;
}

const useBearStore = create<BearState>()(
  devtools(
    persist(
      (set) => ({
        bears: 0,
        increase: (by = 1) => set(state => ({ bears: state.bears + by })),
        reset: () => set({ bears: 0 }),
      }),
      { name: 'bear-storage' } // localStorage key
    ),
    { name: 'BearStore' } // DevTools display name
  )
);

// Usage — select only what you need to minimize re-renders
function BearCounter() {
  const bears = useBearStore(state => state.bears);
  return <p>{bears} bears</p>;
}

function BearControls() {
  const increase = useBearStore(state => state.increase);
  const reset = useBearStore(state => state.reset);
  return (
    <>
      <button onClick={() => increase()}>+1</button>
      <button onClick={() => increase(10)}>+10</button>
      <button onClick={reset}>Reset</button>
    </>
  );
}
```

### Slices Pattern (Large Stores)

```typescript
import { create, StateCreator } from 'zustand';

// Slice 1: auth
interface AuthSlice {
  user: User | null;
  login: (user: User) => void;
  logout: () => void;
}

const createAuthSlice: StateCreator<AuthSlice & CartSlice, [], [], AuthSlice> = set => ({
  user: null,
  login: (user) => set({ user }),
  logout: () => set({ user: null }),
});

// Slice 2: cart
interface CartSlice {
  items: CartItem[];
  addItem: (item: CartItem) => void;
  removeItem: (id: string) => void;
}

const createCartSlice: StateCreator<AuthSlice & CartSlice, [], [], CartSlice> = set => ({
  items: [],
  addItem: (item) => set(state => ({ items: [...state.items, item] })),
  removeItem: (id) => set(state => ({ items: state.items.filter(i => i.id !== id) })),
});

// Combined store
const useStore = create<AuthSlice & CartSlice>()((...args) => ({
  ...createAuthSlice(...args),
  ...createCartSlice(...args),
}));

// Focused selectors — each component subscribes to only its slice
export const useUser = () => useStore(state => state.user);
export const useCart = () => useStore(state => state.items);
export const useCartActions = () =>
  useStore(state => ({ addItem: state.addItem, removeItem: state.removeItem }));
```

---

## Jotai

Atomic state model — compose fine-grained atoms instead of one store.

```typescript
import { atom, useAtom, useAtomValue, useSetAtom } from 'jotai';
import { atomWithStorage, atomWithReset } from 'jotai/utils';

// Primitive atoms
const countAtom = atom(0);
const nameAtom = atom('');

// Derived (read-only) atom
const doubledAtom = atom(get => get(countAtom) * 2);

// Write-only atom
const incrementAtom = atom(null, (get, set) => {
  set(countAtom, get(countAtom) + 1);
});

// Async atom — integrates with Suspense
const userAtom = atom(async () => {
  const res = await fetch('/api/me');
  return res.json() as Promise<User>;
});

// Persistent atom (localStorage)
const themeAtom = atomWithStorage<'light' | 'dark'>('theme', 'light');

// Resettable atom
const filterAtom = atomWithReset({ search: '', category: 'all' });

// Usage
function Counter() {
  const [count, setCount] = useAtom(countAtom);
  const doubled = useAtomValue(doubledAtom);
  const increment = useSetAtom(incrementAtom);

  return (
    <div>
      <p>Count: {count}, Doubled: {doubled}</p>
      <button onClick={increment}>Increment</button>
      <button onClick={() => setCount(0)}>Reset</button>
    </div>
  );
}
```

---

## Redux Toolkit

Best for large teams, complex state machines, and when time-travel debugging matters.

### Slice + Thunk

```typescript
import {
  createSlice,
  createAsyncThunk,
  PayloadAction,
  createEntityAdapter,
} from '@reduxjs/toolkit';
import type { RootState, AppDispatch } from './store';

// Entity adapter for normalized CRUD
const usersAdapter = createEntityAdapter<User>();

// Async thunk for data fetching
export const fetchUsers = createAsyncThunk(
  'users/fetchAll',
  async (_, { rejectWithValue }) => {
    try {
      const res = await fetch('/api/users');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return (await res.json()) as User[];
    } catch (err) {
      return rejectWithValue((err as Error).message);
    }
  }
);

// Slice
const usersSlice = createSlice({
  name: 'users',
  initialState: usersAdapter.getInitialState({
    status: 'idle' as 'idle' | 'loading' | 'succeeded' | 'failed',
    error: null as string | null,
  }),
  reducers: {
    userAdded: usersAdapter.addOne,
    userUpdated: usersAdapter.updateOne,
    userRemoved: usersAdapter.removeOne,
  },
  extraReducers: builder => {
    builder
      .addCase(fetchUsers.pending, state => {
        state.status = 'loading';
      })
      .addCase(fetchUsers.fulfilled, (state, action) => {
        state.status = 'succeeded';
        usersAdapter.setAll(state, action.payload);
      })
      .addCase(fetchUsers.rejected, (state, action) => {
        state.status = 'failed';
        state.error = action.payload as string;
      });
  },
});

// Selectors from adapter
export const { selectAll: selectAllUsers, selectById: selectUserById } =
  usersAdapter.getSelectors((state: RootState) => state.users);

// Custom selectors
export const selectUsersStatus = (state: RootState) => state.users.status;

export const { userAdded, userUpdated, userRemoved } = usersSlice.actions;
export default usersSlice.reducer;
```

### RTK Query (preferred over sagas/thunks for data fetching)

```typescript
import { createApi, fetchBaseQuery } from '@reduxjs/toolkit/query/react';

export const apiSlice = createApi({
  reducerPath: 'api',
  baseQuery: fetchBaseQuery({
    baseUrl: '/api',
    prepareHeaders: (headers, { getState }) => {
      const token = (getState() as RootState).auth.token;
      if (token) headers.set('Authorization', `Bearer ${token}`);
      return headers;
    },
  }),
  tagTypes: ['User', 'Post'],
  endpoints: builder => ({
    getUsers: builder.query<User[], void>({
      query: () => '/users',
      providesTags: ['User'],
    }),
    getUserById: builder.query<User, string>({
      query: id => `/users/${id}`,
      providesTags: (result, error, id) => [{ type: 'User', id }],
    }),
    createUser: builder.mutation<User, Partial<User>>({
      query: body => ({ url: '/users', method: 'POST', body }),
      invalidatesTags: ['User'],
    }),
    updateUser: builder.mutation<User, Pick<User, 'id'> & Partial<User>>({
      query: ({ id, ...patch }) => ({ url: `/users/${id}`, method: 'PATCH', body: patch }),
      invalidatesTags: (result, error, { id }) => [{ type: 'User', id }],
    }),
  }),
});

export const {
  useGetUsersQuery,
  useGetUserByIdQuery,
  useCreateUserMutation,
  useUpdateUserMutation,
} = apiSlice;

// Usage
function UserList() {
  const { data: users = [], isLoading, isError } = useGetUsersQuery();
  const [createUser, { isLoading: isCreating }] = useCreateUserMutation();

  if (isLoading) return <Spinner />;
  if (isError) return <Error />;

  return (
    <>
      {users.map(u => <UserCard key={u.id} user={u} />)}
      <button onClick={() => createUser({ name: 'New User' })} disabled={isCreating}>
        Add User
      </button>
    </>
  );
}
```

---

## TanStack Query (React Query)

The standard for server state. Handles caching, background refetch, stale-while-revalidate.

```typescript
import {
  useQuery,
  useMutation,
  useQueryClient,
  useInfiniteQuery,
  QueryClient,
  QueryClientProvider,
} from '@tanstack/react-query';

// Setup
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 60 * 1000, // data fresh for 1 minute
      retry: 3,
    },
  },
});

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <Router />
    </QueryClientProvider>
  );
}

// Basic query
function UserProfile({ userId }: { userId: string }) {
  const { data: user, isLoading, error, refetch } = useQuery({
    queryKey: ['users', userId],
    queryFn: () => fetchUser(userId),
    enabled: !!userId, // only run when userId is truthy
    staleTime: 5 * 60 * 1000, // override: 5 minutes
  });

  if (isLoading) return <Skeleton />;
  if (error) return <Error onRetry={refetch} />;
  return <div>{user?.name}</div>;
}

// Mutation with optimistic update
function DeleteButton({ userId }: { userId: string }) {
  const queryClient = useQueryClient();

  const mutation = useMutation({
    mutationFn: (id: string) => deleteUser(id),

    // Optimistic update
    onMutate: async (id) => {
      await queryClient.cancelQueries({ queryKey: ['users'] });
      const previousUsers = queryClient.getQueryData<User[]>(['users']);

      queryClient.setQueryData<User[]>(['users'], old =>
        old?.filter(u => u.id !== id) ?? []
      );

      return { previousUsers }; // context for rollback
    },

    // Rollback on error
    onError: (err, id, context) => {
      if (context?.previousUsers) {
        queryClient.setQueryData(['users'], context.previousUsers);
      }
    },

    // Always invalidate after settle
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['users'] });
    },
  });

  return (
    <button
      onClick={() => mutation.mutate(userId)}
      disabled={mutation.isPending}
    >
      {mutation.isPending ? 'Deleting...' : 'Delete'}
    </button>
  );
}

// Infinite query (pagination / infinite scroll)
function PostFeed() {
  const {
    data,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
  } = useInfiniteQuery({
    queryKey: ['posts'],
    queryFn: ({ pageParam }) => fetchPosts({ cursor: pageParam, limit: 20 }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: lastPage => lastPage.nextCursor,
  });

  const posts = data?.pages.flatMap(page => page.posts) ?? [];

  return (
    <>
      {posts.map(post => <PostCard key={post.id} post={post} />)}
      <button
        onClick={() => fetchNextPage()}
        disabled={!hasNextPage || isFetchingNextPage}
      >
        {isFetchingNextPage ? 'Loading...' : 'Load More'}
      </button>
    </>
  );
}

// Prefetch on hover (instant navigation feel)
function PostLink({ postId }: { postId: string }) {
  const queryClient = useQueryClient();
  return (
    <a
      href={`/posts/${postId}`}
      onMouseEnter={() => queryClient.prefetchQuery({
        queryKey: ['posts', postId],
        queryFn: () => fetchPost(postId),
      })}
    >
      Read More
    </a>
  );
}
```

---

## React Hook Form

```typescript
import { useForm, Controller, SubmitHandler } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';

// 1. Define schema with Zod
const profileSchema = z.object({
  name: z.string().min(2, 'Name must be at least 2 characters'),
  email: z.string().email('Invalid email address'),
  age: z.coerce.number().int().min(18, 'Must be at least 18').max(120),
  role: z.enum(['admin', 'user', 'moderator']),
  bio: z.string().max(500).optional(),
});

type ProfileForm = z.infer<typeof profileSchema>;

// 2. Form component
function ProfileForm({ onSave }: { onSave: (data: ProfileForm) => Promise<void> }) {
  const {
    register,
    handleSubmit,
    control,
    formState: { errors, isSubmitting, isDirty },
    reset,
  } = useForm<ProfileForm>({
    resolver: zodResolver(profileSchema),
    defaultValues: { name: '', email: '', age: 18, role: 'user' },
  });

  const onSubmit: SubmitHandler<ProfileForm> = async data => {
    await onSave(data);
    reset(); // reset to defaultValues after success
  };

  return (
    <form onSubmit={handleSubmit(onSubmit)} noValidate>
      <div>
        <label htmlFor="name">Name</label>
        <input
          id="name"
          {...register('name')}
          aria-describedby={errors.name ? 'name-error' : undefined}
          aria-invalid={!!errors.name}
        />
        {errors.name && (
          <span id="name-error" role="alert">{errors.name.message}</span>
        )}
      </div>

      {/* Controller for third-party input components */}
      <Controller
        name="role"
        control={control}
        render={({ field }) => (
          <Select
            value={field.value}
            onChange={field.onChange}
            options={['admin', 'user', 'moderator']}
          />
        )}
      />

      <button type="submit" disabled={isSubmitting || !isDirty}>
        {isSubmitting ? 'Saving...' : 'Save Profile'}
      </button>
    </form>
  );
}
```

---

## URL State

```typescript
import { useSearchParams } from 'react-router-dom';

// Built-in useSearchParams (React Router v6)
function ProductFilters() {
  const [searchParams, setSearchParams] = useSearchParams();

  const category = searchParams.get('category') ?? 'all';
  const page = Number(searchParams.get('page') ?? '1');

  const setFilter = (key: string, value: string) => {
    setSearchParams(prev => {
      prev.set(key, value);
      if (key !== 'page') prev.set('page', '1'); // reset page on filter change
      return prev;
    });
  };

  return (
    <div>
      <select
        value={category}
        onChange={e => setFilter('category', e.target.value)}
      >
        <option value="all">All</option>
        <option value="shoes">Shoes</option>
      </select>
      <Pagination currentPage={page} onPageChange={p => setFilter('page', String(p))} />
    </div>
  );
}

// nuqs — type-safe URL state (Next.js or any framework)
// npm install nuqs
import { useQueryState, parseAsInteger, parseAsString } from 'nuqs';

function FilterPage() {
  const [page, setPage] = useQueryState('page', parseAsInteger.withDefault(1));
  const [search, setSearch] = useQueryState('q', parseAsString.withDefault(''));

  return (
    <div>
      <input value={search} onChange={e => setSearch(e.target.value)} />
      <button onClick={() => setPage(p => p + 1)}>Next page ({page})</button>
    </div>
  );
}
```

---

## Anti-patterns

| Anti-pattern | Problem | Fix |
|--------------|---------|-----|
| `useState` + `useEffect` for server data | Manual loading/error/cache management, stale data | TanStack Query |
| Single massive Context for all global state | Every consumer re-renders on any change | Split contexts by update frequency |
| Putting functions in Context value without `useMemo` | New object reference every render | `useMemo` the value |
| Zustand selectors that return objects | New object reference every call triggers re-render | Select primitives; or use `shallow` equality: `useStore(state => state.items, shallow)` |
| `useEffect` to sync two pieces of state | Double render, complexity | Derive state during render or use `useReducer` |
| Redux for everything including server data | Over-normalized, async complexity | RTK Query or TanStack Query for server state |
| No staleTime in TanStack Query | Constant background refetches on every mount | Set appropriate `staleTime` per query |
