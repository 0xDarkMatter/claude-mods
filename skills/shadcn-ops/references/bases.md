# Base UI, Radix and React Aria

shadcn/ui ships each component for three primitive libraries ("bases"). The base decides
the component API, so code written for one base is often wrong in another. Adapted from the
official shadcn skill's `rules/base-vs-radix.md` (shadcn-ui/ui, MIT licence); base facts
checked against the ui.shadcn.com changelog (July 2026 entries) and the registry sources on
2026-11-10.

## Contents

- [Choosing and reading the base](#choosing-and-reading-the-base)
- [Custom triggers: asChild vs render](#custom-triggers-aschild-vs-render)
- [Select](#select)
- [ToggleGroup, Slider, Accordion](#togglegroup-slider-accordion)
- [Toasts by base](#toasts-by-base)
- [React Aria](#react-aria)
- [Changing base](#changing-base)

## Choosing and reading the base

| Base | `init` flag | Package | Notes |
|---|---|---|---|
| Base UI | `--base base` (the default) | `@base-ui/react` | default since July 2026; the only base with the Toast component |
| Radix | `--base radix` | `radix-ui` | the original; "not being deprecated", components ship for both |
| React Aria | `--base aria` | `react-aria-components` | added July 2026; all eight styles |

Existing projects keep their base. Read it before writing any component code:
`$SHADCN info --json` (field `base`), or the prefix of `style` in components.json
(`radix-nova` is Radix; legacy `new-york` is Radix too). For another base's API,
`$SHADCN docs select --base aria`.

## Custom triggers: asChild vs render

Radix replaces the rendered element with `asChild`; Base UI with a `render` prop. Never
wrap a trigger's child in an extra element.

```tsx
// Radix
<DialogTrigger asChild>
  <Button>Open</Button>
</DialogTrigger>

// Base UI
<DialogTrigger render={<Button />}>Open</DialogTrigger>
```

This applies to every trigger and close part (`DialogTrigger`, `SheetTrigger`,
`AlertDialogTrigger`, `DropdownMenuTrigger`, `PopoverTrigger`, `TooltipTrigger`,
`CollapsibleTrigger`, `DialogClose`, `SheetClose`) and to `NavigationMenuLink`,
`BreadcrumbLink`, `SidebarMenuButton`, `Badge`, `Item`.

Base UI only: when `render` turns a button into a non-button (`<a>`, `<span>`), add
`nativeButton={false}`, or keyboard and ARIA behaviour is wrong.

```tsx
<Button render={<a href="/docs" />} nativeButton={false}>Read the docs</Button>   // Base UI
<Button asChild><a href="/docs">Read the docs</a></Button>                         // Radix
```

## Select

| | Base UI | Radix |
|---|---|---|
| Items | `items` prop on `Select` (array of `{ label, value }`) plus the JSX | JSX only |
| Placeholder | an item with `value: null` | `<SelectValue placeholder="..." />` |
| Positioning | `<SelectContent alignItemWithTrigger={false} side="bottom">` | `<SelectContent position="popper">` |
| Multiple | `multiple`, `defaultValue={[]}`, render function in `SelectValue` | single only |
| Object values | `itemToStringValue={(v) => v.name}` | strings only |

```tsx
// Base UI
const items = [{ label: "Select a role", value: null }, { label: "Admin", value: "admin" }]
<Select items={items}>
  <SelectTrigger><SelectValue /></SelectTrigger>
  <SelectContent>
    <SelectGroup>
      {items.map((i) => <SelectItem key={String(i.value)} value={i.value}>{i.label}</SelectItem>)}
    </SelectGroup>
  </SelectContent>
</Select>
```

## ToggleGroup, Slider, Accordion

| Component | Base UI | Radix |
|---|---|---|
| ToggleGroup | single by default, `multiple` boolean; `defaultValue` always an array | `type="single"` / `type="multiple"`; string value for single |
| Slider (one thumb) | `defaultValue={50}` | `defaultValue={[50]}` |
| Accordion | no `type`; `multiple` boolean; `defaultValue={["item-1"]}` | `type="single" collapsible defaultValue="item-1"` |

Controlled single ToggleGroup in Base UI wraps and unwraps the array:
`value={[value]} onValueChange={(v) => setValue(v[0])}`. A controlled range Slider in Base
UI may need `onValueChange={(v) => setValue(v as number[])}`.

## Toasts by base

- **Base UI:** the `toast` component (`$SHADCN add toast`): render `<Toaster />` in the
  root layout and call `toast.add({ title, description, type })` from
  `@/components/ui/toast`. Types: `success`, `info`, `warning`, `error`, `loading`;
  `toast.promise` moves one toast through loading to success or error.
- **Radix and React Aria:** Sonner (`$SHADCN add sonner`): `<Toaster />` once, then
  `toast.success(...)`, `toast.error(...)`, `toast("Deleted", { action: { label: "Undo",
  onClick } })` from `sonner`.

The old Radix `toast` with a `use-toast` hook was retired in favour of Sonner when the
components moved to Tailwind v4; replace it rather than extend it.

## React Aria

React Aria components keep React Aria's own composition and state props, not Radix's
`asChild` or Base UI's `render`. The registry scopes React Aria's state selectors and
dependencies to the aria base. Before writing or fixing one, read its page:
`$SHADCN docs <component> --base aria` and fetch the URLs. Don't port Radix or Base UI
props across by analogy.

## Changing base

There is no CLI command that converts a whole project between bases. `migrate radix` only
moves `@radix-ui/react-*` imports to the unified `radix-ui` package; it keeps Radix. The
July 2026 changelog describes migrating Radix components to Base UI one at a time with the
official agent skill, on a branch, one commit per component, with both libraries installed
meanwhile: mechanical changes such as `asChild` to `render` are applied and behaviour
changes are flagged. Do the same by hand with this file: one component per commit, typecheck
and test each, and keep the branch until the last one lands.
