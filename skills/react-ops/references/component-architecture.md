# Component Architecture

Patterns for structuring React components: compound components, HOC, render props, portals, refs, and polymorphic components.

---

## Compound Components

Compound components share implicit state through Context. The parent owns state; children consume it without prop drilling.

```tsx
import {
  createContext,
  useContext,
  useState,
  ReactNode,
  KeyboardEvent,
} from 'react';

// --- Types ---
interface TabsContextValue {
  activeIndex: number;
  setActiveIndex: (index: number) => void;
}

// --- Context ---
const TabsContext = createContext<TabsContextValue | null>(null);

function useTabsContext() {
  const ctx = useContext(TabsContext);
  if (!ctx) throw new Error('Tabs sub-components must be used within <Tabs>');
  return ctx;
}

// --- Compound Components ---

function Tabs({
  children,
  defaultIndex = 0,
}: {
  children: ReactNode;
  defaultIndex?: number;
}) {
  const [activeIndex, setActiveIndex] = useState(defaultIndex);
  return (
    <TabsContext.Provider value={{ activeIndex, setActiveIndex }}>
      <div className="tabs">{children}</div>
    </TabsContext.Provider>
  );
}

function TabList({ children }: { children: ReactNode }) {
  return (
    <div role="tablist" className="tab-list">
      {children}
    </div>
  );
}

function Tab({ children, index }: { children: ReactNode; index: number }) {
  const { activeIndex, setActiveIndex } = useTabsContext();
  const isActive = activeIndex === index;

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') setActiveIndex(index);
  };

  return (
    <button
      role="tab"
      aria-selected={isActive}
      tabIndex={isActive ? 0 : -1}
      onClick={() => setActiveIndex(index)}
      onKeyDown={handleKeyDown}
      className={isActive ? 'tab tab--active' : 'tab'}
    >
      {children}
    </button>
  );
}

function TabPanels({ children }: { children: ReactNode }) {
  return <div className="tab-panels">{children}</div>;
}

function TabPanel({ children, index }: { children: ReactNode; index: number }) {
  const { activeIndex } = useTabsContext();
  if (activeIndex !== index) return null;
  return (
    <div role="tabpanel" className="tab-panel">
      {children}
    </div>
  );
}

// Attach as static properties
Tabs.List = TabList;
Tabs.Tab = Tab;
Tabs.Panels = TabPanels;
Tabs.Panel = TabPanel;

// --- Usage ---
function App() {
  return (
    <Tabs defaultIndex={0}>
      <Tabs.List>
        <Tabs.Tab index={0}>Profile</Tabs.Tab>
        <Tabs.Tab index={1}>Settings</Tabs.Tab>
      </Tabs.List>
      <Tabs.Panels>
        <Tabs.Panel index={0}>Profile content</Tabs.Panel>
        <Tabs.Panel index={1}>Settings content</Tabs.Panel>
      </Tabs.Panels>
    </Tabs>
  );
}
```

---

## Render Props

Render props delegate rendering to the consumer. Use for headless/unstyled component libraries where the logic is fixed but appearance varies.

```tsx
import { useState, ReactNode } from 'react';

interface ToggleRenderProps {
  on: boolean;
  toggle: () => void;
  setOn: (value: boolean) => void;
}

function Toggle({
  initial = false,
  children,
}: {
  initial?: boolean;
  children: (props: ToggleRenderProps) => ReactNode;
}) {
  const [on, setOn] = useState(initial);
  return <>{children({ on, toggle: () => setOn(v => !v), setOn })}</>;
}

// Usage: consumer controls rendering
function DarkModeButton() {
  return (
    <Toggle>
      {({ on, toggle }) => (
        <button
          onClick={toggle}
          aria-label={on ? 'Switch to light mode' : 'Switch to dark mode'}
        >
          {on ? '🌙' : '☀️'}
        </button>
      )}
    </Toggle>
  );
}

// Prefer custom hooks over render props in modern React —
// they achieve the same reuse with less JSX nesting
function useToggle(initial = false) {
  const [on, setOn] = useState(initial);
  return { on, toggle: () => setOn(v => !v), setOn };
}
```

---

## Higher-Order Components (HOC)

HOCs wrap a component to inject props or add behavior. Prefer custom hooks for pure logic; use HOCs when you need to conditionally render or wrap JSX.

```tsx
import { ComponentType, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';

// --- Auth HOC ---
interface WithAuthOptions {
  redirectTo?: string;
}

function withAuth<P extends object>(
  Component: ComponentType<P>,
  options: WithAuthOptions = {}
) {
  const { redirectTo = '/login' } = options;

  function AuthenticatedComponent(props: P) {
    const { user, isLoading } = useAuth();
    const navigate = useNavigate();

    useEffect(() => {
      if (!isLoading && !user) navigate(redirectTo);
    }, [user, isLoading, navigate]);

    if (isLoading) return <FullPageSpinner />;
    if (!user) return null;

    return <Component {...props} />;
  }

  // Preserve display name for DevTools
  AuthenticatedComponent.displayName = `withAuth(${Component.displayName ?? Component.name})`;
  return AuthenticatedComponent;
}

// Usage
const ProtectedDashboard = withAuth(Dashboard);
const AdminPanel = withAuth(AdminDashboard, { redirectTo: '/unauthorized' });

// --- Logging HOC ---
function withLogging<P extends object>(
  Component: ComponentType<P>,
  componentName: string
) {
  function LoggedComponent(props: P) {
    useEffect(() => {
      console.log(`[Mount] ${componentName}`);
      return () => console.log(`[Unmount] ${componentName}`);
    }, []);

    return <Component {...props} />;
  }

  LoggedComponent.displayName = `withLogging(${componentName})`;
  return LoggedComponent;
}
```

---

## Controlled vs Uncontrolled Components

### Controlled

```tsx
import { useState } from 'react';

// Controlled: parent owns and controls the value
function ControlledInput({
  value,
  onChange,
  label,
}: {
  value: string;
  onChange: (value: string) => void;
  label: string;
}) {
  return (
    <label>
      {label}
      <input
        type="text"
        value={value}
        onChange={e => onChange(e.target.value)}
      />
    </label>
  );
}

function Parent() {
  const [name, setName] = useState('');
  return <ControlledInput value={name} onChange={setName} label="Name" />;
}
```

### Uncontrolled with Imperative Handle

```tsx
import { forwardRef, useImperativeHandle, useRef, useState } from 'react';

interface InputHandle {
  focus: () => void;
  clear: () => void;
  getValue: () => string;
}

// Hybrid: uncontrolled internally, but exposes imperative API via ref
const SmartInput = forwardRef<InputHandle, { defaultValue?: string }>(
  function SmartInput({ defaultValue = '' }, ref) {
    const inputRef = useRef<HTMLInputElement>(null);
    const [value, setValue] = useState(defaultValue);

    useImperativeHandle(ref, () => ({
      focus: () => inputRef.current?.focus(),
      clear: () => setValue(''),
      getValue: () => value,
    }));

    return (
      <input
        ref={inputRef}
        value={value}
        onChange={e => setValue(e.target.value)}
      />
    );
  }
);

// Usage
function Form() {
  const inputRef = useRef<InputHandle>(null);

  const handleSubmit = () => {
    const value = inputRef.current?.getValue();
    if (!value?.trim()) {
      inputRef.current?.focus();
      return;
    }
    submitForm(value);
    inputRef.current?.clear();
  };

  return (
    <>
      <SmartInput ref={inputRef} defaultValue="" />
      <button onClick={handleSubmit}>Submit</button>
    </>
  );
}
```

---

## Error Boundaries

Error boundaries must be class components. Use `react-error-boundary` package in production for less boilerplate.

```tsx
import { Component, ErrorInfo, ReactNode } from 'react';

interface Props {
  children: ReactNode;
  fallback: ReactNode | ((error: Error, reset: () => void) => ReactNode);
  onError?: (error: Error, info: ErrorInfo) => void;
}

interface State {
  hasError: boolean;
  error: Error | null;
}

class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false, error: null };

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Log to error tracking service (Sentry, Datadog, etc.)
    this.props.onError?.(error, info);
    console.error('ErrorBoundary caught:', error, info.componentStack);
  }

  reset = () => this.setState({ hasError: false, error: null });

  render() {
    if (this.state.hasError && this.state.error) {
      const { fallback } = this.props;
      return typeof fallback === 'function'
        ? fallback(this.state.error, this.reset)
        : fallback;
    }
    return this.props.children;
  }
}

// Usage with error recovery
function App() {
  return (
    <ErrorBoundary
      fallback={(error, reset) => (
        <div role="alert">
          <h2>Something went wrong</h2>
          <p>{error.message}</p>
          <button onClick={reset}>Try Again</button>
        </div>
      )}
      onError={(error) => Sentry.captureException(error)}
    >
      <Dashboard />
    </ErrorBoundary>
  );
}

// react-error-boundary package (recommended for production)
import { ErrorBoundary } from 'react-error-boundary';

function ErrorFallback({ error, resetErrorBoundary }: {
  error: Error;
  resetErrorBoundary: () => void;
}) {
  return (
    <div role="alert">
      <p>{error.message}</p>
      <button onClick={resetErrorBoundary}>Retry</button>
    </div>
  );
}

<ErrorBoundary FallbackComponent={ErrorFallback} onReset={() => queryClient.clear()}>
  <App />
</ErrorBoundary>
```

---

## Portals

Portals render children into a DOM node outside the current React tree. Useful for modals, tooltips, and toasts that need to escape overflow/z-index constraints.

```tsx
import { createPortal } from 'react-dom';
import { useEffect, useRef, ReactNode } from 'react';

function Modal({
  isOpen,
  onClose,
  children,
  title,
}: {
  isOpen: boolean;
  onClose: () => void;
  children: ReactNode;
  title: string;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  // Trap focus and handle Escape key
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;

    if (isOpen) {
      dialog.showModal();
    } else {
      dialog.close();
    }
  }, [isOpen]);

  if (!isOpen) return null;

  // Renders outside current DOM tree, into document.body
  return createPortal(
    <dialog
      ref={dialogRef}
      aria-labelledby="modal-title"
      aria-modal="true"
      onClose={onClose}
    >
      <h2 id="modal-title">{title}</h2>
      <div>{children}</div>
      <button onClick={onClose} aria-label="Close modal">
        &times;
      </button>
    </dialog>,
    document.body
  );
}
```

---

## forwardRef

```tsx
import { forwardRef, InputHTMLAttributes } from 'react';

interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string;
  error?: string;
}

// React 19: ref is now a regular prop, forwardRef not required
// For React 18 and below:
const Input = forwardRef<HTMLInputElement, InputProps>(
  function Input({ label, error, id, ...props }, ref) {
    const inputId = id ?? label.toLowerCase().replace(/\s+/g, '-');

    return (
      <div className="input-wrapper">
        <label htmlFor={inputId}>{label}</label>
        <input
          ref={ref}
          id={inputId}
          aria-describedby={error ? `${inputId}-error` : undefined}
          aria-invalid={!!error}
          {...props}
        />
        {error && (
          <span id={`${inputId}-error`} role="alert" className="error">
            {error}
          </span>
        )}
      </div>
    );
  }
);

Input.displayName = 'Input';

// React 19 equivalent (no forwardRef needed):
function InputV19({ label, ref, error, id, ...props }: InputProps & {
  ref?: React.Ref<HTMLInputElement>;
}) {
  const inputId = id ?? label.toLowerCase().replace(/\s+/g, '-');
  return (
    <div>
      <label htmlFor={inputId}>{label}</label>
      <input ref={ref} id={inputId} {...props} />
    </div>
  );
}
```

---

## Slot Pattern

Named slots via props allow flexible composition without rigid component trees.

```tsx
import { ReactNode } from 'react';

interface CardProps {
  header: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  aside?: ReactNode;
}

function Card({ header, children, footer, aside }: CardProps) {
  return (
    <div className="card">
      <div className="card__header">{header}</div>
      <div className="card__body">
        <div className="card__content">{children}</div>
        {aside && <aside className="card__aside">{aside}</aside>}
      </div>
      {footer && <footer className="card__footer">{footer}</footer>}
    </div>
  );
}

// Usage: consumer fills each slot independently
function ProductCard({ product }: { product: Product }) {
  return (
    <Card
      header={<img src={product.image} alt={product.name} />}
      footer={<AddToCartButton productId={product.id} />}
      aside={<ProductRating rating={product.rating} />}
    >
      <h3>{product.name}</h3>
      <p>{product.description}</p>
    </Card>
  );
}
```

---

## Polymorphic Components (as prop)

```tsx
import { ComponentPropsWithoutRef, ElementType, ReactNode } from 'react';

// Generic polymorphic component type
type PolymorphicProps<C extends ElementType, P = object> = {
  as?: C;
  children?: ReactNode;
} & P &
  Omit<ComponentPropsWithoutRef<C>, keyof P | 'as' | 'children'>;

// Button that can render as <button>, <a>, or any element
function Button<C extends ElementType = 'button'>({
  as,
  children,
  variant = 'primary',
  ...props
}: PolymorphicProps<C, { variant?: 'primary' | 'secondary' | 'ghost' }>) {
  const Component = as ?? 'button';
  return (
    <Component className={`btn btn--${variant}`} {...props}>
      {children}
    </Component>
  );
}

// Usage — TypeScript infers correct HTML attributes
<Button onClick={() => {}}>Click me</Button>             // renders <button>
<Button as="a" href="/about">About</Button>               // renders <a>, href is valid
<Button as="a" href="/about" variant="secondary">Link</Button>
```

---

## Container / Presentational Split

Largely superseded by hooks, but useful when separating data-fetching from display for testing.

```tsx
// Presentational: receives data as props, no fetching
function UserListView({
  users,
  isLoading,
  error,
  onDelete,
}: {
  users: User[];
  isLoading: boolean;
  error: Error | null;
  onDelete: (id: string) => void;
}) {
  if (isLoading) return <Spinner />;
  if (error) return <ErrorMessage error={error} />;
  return (
    <ul>
      {users.map(user => (
        <li key={user.id}>
          {user.name}
          <button onClick={() => onDelete(user.id)}>Delete</button>
        </li>
      ))}
    </ul>
  );
}

// Container: owns data-fetching, passes to presentational
function UserListContainer() {
  const { data: users = [], isLoading, error } = useQuery(['users'], fetchUsers);
  const deleteMutation = useMutation(deleteUser, {
    onSuccess: () => queryClient.invalidateQueries(['users']),
  });

  return (
    <UserListView
      users={users}
      isLoading={isLoading}
      error={error ?? null}
      onDelete={id => deleteMutation.mutate(id)}
    />
  );
}
```

---

## Patterns to Avoid

| Anti-pattern | Problem | Fix |
|--------------|---------|-----|
| Prop drilling past 3 levels | Hard to maintain, tightly coupled | Compound components or Context |
| HOC for pure logic (no JSX needed) | Creates wrapper component unnecessarily | Custom hook instead |
| Huge single component (500+ lines) | Hard to test, reuse, understand | Split by responsibility |
| `any` in component props | Loses type safety | Type all props; use `unknown` with narrowing |
| `key` on React.Fragment without need | Unnecessary | Only add key when rendering lists |
| Mutable props | Breaks React's unidirectional data flow | Lift state or use callback |
| Boolean props without clear intent | `<Input disabled />` vs `<Input disabled={false}>` | Always explicit: `disabled={isLoading}` |
