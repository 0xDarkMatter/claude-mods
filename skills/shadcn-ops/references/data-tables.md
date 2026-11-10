# Data tables (TanStack Table v9)

shadcn/ui has no data-table component to `add`: it has a guide that builds one from the
`Table` component and TanStack Table. Since 2026 the guide uses TanStack Table v9, whose API
differs from the v8 code most tutorials and older projects contain. Facts from
ui.shadcn.com/docs/components/data-table, the guide's example source in shadcn-ui/ui, and
TanStack Table's React pagination guide, checked 2026-11-10.

## Contents

- [Before you start](#before-you-start)
- [Files](#files)
- [Features: register what you use](#features-register-what-you-use)
- [Columns and row actions](#columns-and-row-actions)
- [The table component](#the-table-component)
- [Server-side data](#server-side-data)
- [URL-synced table state](#url-synced-table-state)
- [Reusable parts](#reusable-parts)
- [Loading, empty and error states](#loading-empty-and-error-states)
- [v8 code in an existing project](#v8-code-in-an-existing-project)

## Before you start

```bash
$SHADCN add table button checkbox dropdown-menu input select skeleton
pnpm add @tanstack/react-table          # a new dependency: 7-day cooldown + scan first
```

Check which major the project already has (`pnpm why @tanstack/react-table`). Don't
paste v9 code into a v8 project or the reverse (last section).

## Files

```text
app/(admin)/payments/
  data-table-features.ts   the features object and its type (shared by every file below)
  columns.tsx              column definitions            ("use client")
  data-table.tsx           the table component           ("use client")
  page.tsx                 fetches data; a Server Component in Next.js
```

## Features: register what you use

v9 tables declare their features up front; anything not registered is tree-shaken away and
its APIs don't exist on the types.

```ts
import {
  columnFilteringFeature, columnVisibilityFeature, createFilteredRowModel,
  createPaginatedRowModel, createSortedRowModel, filterFn_includesString,
  rowPaginationFeature, rowSelectionFeature, rowSortingFeature,
  sortFn_alphanumeric, sortFn_text, tableFeatures,
} from "@tanstack/react-table"

export const features = tableFeatures({
  columnFilteringFeature,
  columnVisibilityFeature,
  rowPaginationFeature,
  rowSelectionFeature,
  rowSortingFeature,
  filteredRowModel: createFilteredRowModel(),
  paginatedRowModel: createPaginatedRowModel(),
  sortedRowModel: createSortedRowModel(),
  filterFns: { includesString: filterFn_includesString },
  sortFns: { alphanumeric: sortFn_alphanumeric, text: sortFn_text },
})
export type DataTableFeatures = typeof features   // first generic of ColumnDef, Column, Table, Row
```

Faceted filters (counts per status) add `columnFacetingFeature`,
`facetedRowModel: createFacetedRowModel()` and
`facetedUniqueValues: createFacetedUniqueValues()`.

## Columns and row actions

```tsx
"use client"
import { createColumnHelper } from "@tanstack/react-table"
import type { DataTableFeatures } from "./data-table-features"

export type Payment = { id: string; amount: number; status: "pending" | "success" | "failed"; email: string }
const columnHelper = createColumnHelper<DataTableFeatures, Payment>()

export const columns = columnHelper.columns([
  columnHelper.display({
    id: "select",
    header: ({ table }) => (
      <Checkbox
        checked={table.getIsAllPageRowsSelected() || (table.getIsSomePageRowsSelected() && "indeterminate")}
        onCheckedChange={(v) => table.toggleAllPageRowsSelected(!!v)}
        aria-label="Select all"
      />
    ),
    cell: ({ row }) => (
      <Checkbox checked={row.getIsSelected()} onCheckedChange={(v) => row.toggleSelected(!!v)} aria-label="Select row" />
    ),
    enableSorting: false,
    enableHiding: false,
  }),
  columnHelper.accessor("email", {
    header: ({ column }) => <DataTableColumnHeader column={column} title="Email" />,
  }),
  columnHelper.accessor("amount", {
    header: () => <div className="text-right">Amount</div>,
    cell: ({ row }) => <div className="text-right font-medium tabular-nums">{formatMoney(row.original.amount)}</div>,
  }),
  columnHelper.display({
    id: "actions",
    enableHiding: false,
    cell: ({ row }) => (
      <DropdownMenu>
        <DropdownMenuTrigger asChild>{/* Base UI: render={<Button ... />} */}
          <Button variant="ghost" size="icon-xs"><span className="sr-only">Open menu</span><MoreHorizontal /></Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuGroup>
            <DropdownMenuItem onClick={() => navigator.clipboard.writeText(row.original.id)}>Copy ID</DropdownMenuItem>
            <DropdownMenuItem>View details</DropdownMenuItem>
          </DropdownMenuGroup>
        </DropdownMenuContent>
      </DropdownMenu>
    ),
  }),
])
```

Destructive row actions (delete, refund) open an `AlertDialog` to confirm; never act
straight from the menu item.

## The table component

```tsx
"use client"
export function DataTable({ data }: { data: Payment[] }) {
  const [sorting, setSorting] = React.useState<SortingState>([])
  const [columnFilters, setColumnFilters] = React.useState<ColumnFiltersState>([])
  const [columnVisibility, setColumnVisibility] = React.useState<ColumnVisibilityState>({})
  const [rowSelection, setRowSelection] = React.useState({})

  const table = useTable({
    features, data, columns,
    onSortingChange: setSorting,
    onColumnFiltersChange: setColumnFilters,
    onColumnVisibilityChange: setColumnVisibility,
    onRowSelectionChange: setRowSelection,
    state: { sorting, columnFilters, columnVisibility, rowSelection },
  })

  return (
    <Table>
      <TableHeader>
        {table.getHeaderGroups().map((hg) => (
          <TableRow key={hg.id}>
            {hg.headers.map((h) => (
              <TableHead key={h.id}>{h.isPlaceholder ? null : <table.FlexRender header={h} />}</TableHead>
            ))}
          </TableRow>
        ))}
      </TableHeader>
      <TableBody>
        {table.getRowModel().rows.length ? table.getRowModel().rows.map((row) => (
          <TableRow key={row.id} data-state={row.getIsSelected() && "selected"}>
            {row.getVisibleCells().map((cell) => (
              <TableCell key={cell.id}><table.FlexRender cell={cell} /></TableCell>
            ))}
          </TableRow>
        )) : (
          <TableRow><TableCell colSpan={columns.length} className="h-24 text-center">No results.</TableCell></TableRow>
        )}
      </TableBody>
    </Table>
  )
}
```

A text filter is an `Input` bound to `table.getColumn("email")?.getFilterValue()` /
`setFilterValue`. The selection count is `table.getFilteredSelectedRowModel().rows.length`.

## Server-side data

When the full dataset is too big to load, the server sorts, filters and pages. Register the
features but not their client row models, and tell the table it is manual:

```tsx
const table = useTable({
  features,                                  // rowPaginationFeature, rowSortingFeature, ... no row models
  data: query.data?.rows ?? [],
  rowCount: query.data?.rowCount,            // or pageCount; -1 when unknown
  state: { pagination, sorting, columnFilters },
  onPaginationChange: setPagination,         // { pageIndex, pageSize }
  onSortingChange: setSorting,
  onColumnFiltersChange: setColumnFilters,
  manualPagination: true,
  manualSorting: true,
  manualFiltering: true,
})
```

- Put pagination, sorting and filters in the request (a TanStack Query key, or the URL:
  next section) and keep the previous page visible while the next loads
  (`placeholderData: keepPreviousData`).
- Debounce text filters before they become requests.
- Validate and whitelist sort and filter fields on the server: they arrive as user input.
- Row selection across pages holds row ids, so give rows stable ids (`getRowId`).

## URL-synced table state

An admin list should survive a reload, a shared link and the back button, so the URL's
search params are the source of truth for page, page size, sort and filters, and the
table's `state` is derived from them on every render:

- **Read, don't copy.** Parse the params (with defaults and validation) into
  `{ pagination, sorting, columnFilters }` and pass them as `state`. Don't mirror them in
  `useState`: two sources of truth drift.
- **Write with replace.** In each `on*Change`, compute the next state (the updater may be a
  function of the previous one), serialise it and replace the URL rather than pushing, so
  typing in a filter doesn't add a history entry per key.
- **Reset the page when filters or sort change.** Set `pageIndex` to 0 in the same update,
  or a filter can leave the user on page 7 of 2.
- **Debounce text filters** (about 300 ms) before they reach the URL, and drop params that
  equal their defaults to keep links short.
- **Whitelist on the server.** The server still validates and whitelists every param.

| Router | Read | Write |
|---|---|---|
| Next.js App Router | `searchParams` prop on the page (Server Component), or `useSearchParams()` in the client table, inside a `<Suspense>` boundary | `router.replace(pathname + "?" + params)` from `useRouter` |
| TanStack Router | `validateSearch` on the route (a Standard Schema such as Zod 4 directly), then `Route.useSearch()` | `navigate({ search: (prev) => ({ ...prev, page: 1 }), replace: true })` |
| React Router | `const [params, setParams] = useSearchParams()` | `setParams((p) => { p.set("page", "1"); return p }, { replace: true })` |

nuqs is an optional library that wraps these behind typed `useQueryState` hooks with
parsers and defaults, through an adapter per router (Next.js, React Router, TanStack Router
experimental, plain React). It is a new dependency: cooldown and scan first.

Sources: nextjs.org/docs/app/api-reference/functions/use-search-params,
tanstack.com/router/latest/docs/framework/react/guide/search-params,
reactrouter.com/api/hooks/useSearchParams, nuqs.dev/docs/adapters, checked 2026-11-10.

## Reusable parts

The guide's three building blocks, typed against your features type:

- `DataTableColumnHeader`: a sortable, hideable header (ascending, descending, hide).
- `DataTablePagination`: selection count, rows-per-page `Select` (10 to 50), page indicator,
  first/previous/next/last buttons (each with an `sr-only` label).
- `DataTableViewOptions`: a "View" dropdown of `DropdownMenuCheckboxItem`s toggling column
  visibility.

The `tasks` example on ui.shadcn.com shows them together with faceted filters and a toolbar.

## Loading, empty and error states

- Loading: keep the table frame and render `Skeleton` rows of the expected height (the
  same column count), so the layout doesn't jump.
- Empty because nothing exists: an `Empty` with a primary action ("Create invoice").
  Empty because filters match nothing: the "No results." row plus a reset-filters button.
- Error: an `Alert variant="destructive"` above the table with a retry; never an empty
  table that looks like "no data".

## v8 code in an existing project

v8 code uses `useReactTable`, `getCoreRowModel()`, `getSortedRowModel()`, `flexRender` and
`ColumnDef<TData>`. v9 replaces them with `useTable`, `tableFeatures`, the `create*RowModel()`
factories, `<table.FlexRender />` (the v8 `flexRender` helper still works) and
`ColumnDef<Features, TData>`. Upgrading is its own commit (migrate-ops covers the method);
inside a v8 project, write v8 code and use the shadcn parts (Table, Checkbox, DropdownMenu)
unchanged.
