# Admin dashboards: shell, blocks, overlays, feedback, dark mode

The parts of an admin UI around the data: the sidebar shell, ready-made blocks, dialogs and
sheets, toasts, page states, auth pages and theme switching. Facts from ui.shadcn.com/docs
(sidebar, blocks, dialog, sheet, alert-dialog, toast, sonner, empty, dark-mode) checked
2026-11-10. Data tables, forms and charts have their own references.

## Contents

- [Start from a block](#start-from-a-block)
- [The sidebar shell](#the-sidebar-shell)
- [Dialogs, sheets and confirmations](#dialogs-sheets-and-confirmations)
- [Toasts](#toasts)
- [Page states: loading, empty, error](#page-states-loading-empty-error)
- [Auth pages](#auth-pages)
- [Dark mode](#dark-mode)
- [Accessibility](#accessibility)

## Start from a block

Blocks are whole page sections in the `@shadcn` registry: `dashboard-01` (sidebar, KPI
cards, an interactive chart and a data table), `sidebar-01` to `sidebar-16` (navigation
variants), `login-01` to `login-05`, `signup-01` to `signup-05`, and more at
ui.shadcn.com/blocks.

```bash
$SHADCN add --dry-run dashboard-01      # see every file and component it brings
$SHADCN add dashboard-01
```

A block installs many components and writes page files (in Next.js, `app/dashboard/...`).
Run it with `--dry-run` first, then adapt it: replace the demo data (often a `data.json`
import) with your own source, delete the parts you don't need, and rename routes. The
block's code is yours after the add; it doesn't update.

## The sidebar shell

```tsx
<SidebarProvider>                     {/* open state, mobile sheet, keyboard shortcut */}
  <AppSidebar />                      {/* <Sidebar collapsible="icon" variant="inset"> */}
  <SidebarInset>                      {/* the main area beside an inset sidebar */}
    <header className="flex h-12 items-center gap-2 border-b px-4">
      <SidebarTrigger />
      <Breadcrumb>...</Breadcrumb>
    </header>
    <main className="flex flex-1 flex-col gap-4 p-4">{children}</main>
  </SidebarInset>
</SidebarProvider>
```

- Parts: `Sidebar`, `SidebarHeader`, `SidebarContent`, `SidebarGroup` (+ `Label`,
  `Content`), `SidebarMenu`, `SidebarMenuItem`, `SidebarMenuButton`, `SidebarMenuSub`,
  `SidebarFooter`, `SidebarRail`, `SidebarTrigger`, `SidebarInset`.
- `Sidebar` props: `side` (`left`/`right`), `variant` (`sidebar`, `floating`, `inset`),
  `collapsible` (`offcanvas`, `icon`, `none`). With `collapsible="icon"` every
  `SidebarMenuButton` needs a `tooltip` so the collapsed icons keep a name.
- `useSidebar()` gives `state`, `open`, `setOpen`, `openMobile`, `setOpenMobile`, `isMobile`,
  `toggleSidebar`. The shortcut is Cmd+B / Ctrl+B. Widths come from `SIDEBAR_WIDTH` (16rem)
  and `SIDEBAR_WIDTH_MOBILE` (18rem), or `--sidebar-width` set via `style` on the provider.
- Mark the current page: `SidebarMenuButton isActive` (and `aria-current="page"` on the
  link). Links go through `asChild` (Radix) or `render` (Base UI) so they stay links.
- Colours come from the `--sidebar-*` tokens (theming.md), not classes on the parts.
- To keep the open state across reloads, initialise `defaultOpen` (or controlled `open` /
  `onOpenChange`) from a cookie or stored preference read on the server.

## Dialogs, sheets and confirmations

| Use case | Component |
|---|---|
| A focused task that needs input (create, edit) | `Dialog` |
| Confirm a destructive or irreversible action | `AlertDialog` (no close-on-outside-click; explicit Cancel and Action) |
| Details or filters beside a list | `Sheet` (`side="right"`) |
| Mobile-first bottom panel | `Drawer` |
| Small contextual content on click / quick info on hover | `Popover` / `HoverCard` |

- Every Dialog, Sheet and Drawer has a title (`sr-only` if hidden) and preferably a
  description; focus moves in on open and returns to the trigger on close.
- An edit form in a Dialog: submit, keep the dialog open on validation errors, close only on
  success, then toast.
- The confirm button of an AlertDialog names the action ("Delete 3 users"), uses the
  destructive variant, and shows a Spinner while the request runs.
- Don't add `z-index` to overlays and don't nest dialogs; replace the content or use a Sheet.

## Toasts

The toast component depends on the base (bases.md): Base UI uses `toast.add({ title,
description, type })` from `@/components/ui/toast`; Radix and React Aria use Sonner
(`toast.success(...)` from `sonner`). Either way render `<Toaster />` once in the root
layout, inside `<body>`.

Toast results of actions the user just took (saved, deleted with Undo, failed with a reason).
Don't toast page-load errors (show them in the page), and don't put the only copy of
important information in a toast that disappears.

## Page states: loading, empty, error

| State | Component | Notes |
|---|---|---|
| Loading a section | `Skeleton` in the final layout's shape | Next.js: `loading.tsx` or Suspense fallbacks (nextjs-ops) |
| Loading inside a control | `Spinner` with `data-icon` in the Button, which is `disabled` | no `isLoading` prop exists |
| Nothing yet | `Empty` (`EmptyHeader`, `EmptyMedia variant="icon"`, `EmptyTitle`, `EmptyDescription`, `EmptyContent` with the primary action) | |
| Filters match nothing | an empty table row plus "Clear filters" | different message from "nothing yet" |
| Failed | `Alert variant="destructive"` with what failed and a retry | error boundaries / `error.tsx` catch the rest (react-ops, nextjs-ops) |
| Forbidden | an `Empty` that says the user lacks access, no data leaked in the shell | enforce on the server, not by hiding buttons |

## Auth pages

`login-01` to `login-05` and `signup-01` to `signup-05` are layouts only: email and password
fields, social buttons and links, with no logic. Wire them to your auth library, keep the
form rules (forms.md: labels, `autoComplete="email"`, `autoComplete="current-password"`
or `"new-password"`, errors as text), and never echo whether an email exists. Session,
OAuth and password handling are auth-ops' subject.

## Dark mode

Tokens switch on a `.dark` class on `<html>` (`@custom-variant dark (&:is(.dark *))` in v4).

- **Next.js:** `next-themes`. A `ThemeProvider` wrapper around `NextThemesProvider`, used in
  `app/layout.tsx` with `attribute="class" defaultTheme="system" enableSystem
  disableTransitionOnChange`, and `suppressHydrationWarning` on `<html>`.
- **Vite:** the docs ship a small `ThemeProvider` that stores the choice in localStorage
  (`storageKey="vite-ui-theme"`) and sets the class on `document.documentElement`; `system`
  follows `prefers-color-scheme`. `init --template next|vite` includes dark mode already.
- A `ModeToggle` is a `DropdownMenu` with Light, Dark and System plus an icon button with an
  `sr-only` label.
- Check both themes for contrast, not just light; `className="dark"` on a section renders a
  dark band with the same components.

## Accessibility

shadcn's primitives handle focus traps, roles and keyboard support, but the composition is
yours. In admin UIs check: icon-only buttons and row-action menus have names; tables keep
`TableHead` cells and a caption or heading; selection checkboxes have `aria-label`s; toasts
are not the only error channel; colour is never the only status signal (Badge text);
collapsed-sidebar icons have tooltips. Audit with a11y-ops (axe, keyboard pass, screen
reader) before calling a dashboard done.
