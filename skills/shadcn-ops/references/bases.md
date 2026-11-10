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
`$SHADCN info --json` (field `config.base`), or the prefix of `style` in components.json
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

Base UI only: when a trigger's `render` is not a button (an `InputGroupAddon`, a `<span>`),
add `nativeButton={false}`, or keyboard and ARIA behaviour is wrong:
`<PopoverTrigger render={<InputGroupAddon />} nativeButton={false}>`.

A link that looks like a button is not a Button in Base UI or React Aria: their `Button`
always sets `role="button"`, which hides the link from assistive tech. Style a plain `<a>`
(or the router's `Link`) with `buttonVariants` instead. Radix can still use `asChild`.

```tsx
<a href="/docs" className={buttonVariants({ variant: "outline" })}>Read the docs</a>  // Base UI, React Aria
<Button asChild><a href="/docs">Read the docs</a></Button>                            // Radix
```

## Select

| | Base UI | Radix |
|---|---|---|
| Items | `items` prop on `Select` (array of `{ label, value }`) plus the JSX | JSX only |
| Placeholder | `<SelectValue placeholder="..." />` with `items` on `Select` (an item with `value: null` also works) | `<SelectValue placeholder="..." />` |
| Positioning | `<SelectContent alignItemWithTrigger={false} side="bottom">` | `<SelectContent position="popper">` |
| Multiple | `multiple`, `defaultValue={[]}`, render function in `SelectValue` | single only |
| Object values | `itemToStringValue={(v) => v.name}` | strings only |

```tsx
// Base UI
const items = [{ label: "Admin", value: "admin" }, { label: "Editor", value: "editor" }]
<Select items={items}>
  <SelectTrigger><SelectValue placeholder="Select a role" /></SelectTrigger>
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
props across by analogy. The differences that most often bite:

| Component | React Aria base | Not this (Radix / Base UI habit) |
|---|---|---|
| Select | `<Select placeholder="Theme">` on the root, `<SelectItem id="dark">`, `isInvalid` on `Select` | `SelectValue placeholder`, `SelectItem value`, `aria-invalid` on the trigger |
| ToggleGroup | `selectionMode="single"` or `"multiple"`, `defaultSelectedKeys={["bold"]}`, `id` on each `ToggleGroupItem` | `type` (Radix), `multiple` (Base UI), `defaultValue`, `value` |
| Accordion | `defaultExpandedKeys={["item-1"]}`, `allowsMultipleExpanded`, `id="item-1"` on `AccordionItem` | `type`, `multiple`, `defaultValue`, `value` |
| Dialog | `DialogTrigger` wraps both the `Button` and the `Dialog` (which holds the content) | a `DialogTrigger` beside `DialogContent` |
| Combobox | items keyed by `id`; `value` / `onChange`; `selectionMode="multiple"`; `isInvalid`, `isDisabled` | `items` + `value` props, `onValueChange`, `aria-invalid` |
| Calendar | `CalendarDate` values from `@internationalized/date`; `RangeCalendar` for ranges | JS `Date` and `mode="range"` |
| Toasts | Sonner (`add sonner`); the old `toast` page is a deprecation notice | the Base UI `toast` |

There is no Menubar or NavigationMenu for the aria base: its component list has neither,
so use a `DropdownMenu` per menu, or links in the `Sidebar`, instead.

```tsx
<DialogTrigger>
  <Button>Invite</Button>
  <Dialog>
    <DialogHeader><DialogTitle>Invite a teammate</DialogTitle></DialogHeader>
  </Dialog>
</DialogTrigger>
```

Sources: ui.shadcn.com/docs/components/aria/{select, toggle-group, accordion, dialog,
combobox, calendar, toast}, the component list in the aria docs folder, and the aria
examples in shadcn-ui/ui (`apps/v4/registry/bases/aria/examples/`), checked 2026-11-10.

## Changing base

There is no CLI command that converts a whole project between bases. `migrate radix` only
moves `@radix-ui/react-*` imports to the unified `radix-ui` package; it keeps Radix. The
July 2026 changelog describes migrating Radix components to Base UI one at a time with the
official agent skill, on a branch, one commit per component, with both libraries installed
meanwhile: mechanical changes such as `asChild` to `render` are applied and behaviour
changes are flagged. Do the same by hand with this file: one component per commit, typecheck
and test each, and keep the branch until the last one lands.
