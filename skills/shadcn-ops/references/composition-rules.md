# Composition and styling rules

The rules that separate correct shadcn/ui code from code that merely renders. Adapted from
the official shadcn skill's `rules/styling.md`, `rules/composition.md` and `rules/icons.md`
(shadcn-ui/ui, MIT licence), checked against ui.shadcn.com/docs on 2026-11-10.

## Contents

- [Use what exists](#use-what-exists)
- [Styling](#styling)
- [Structure](#structure)
- [Icons](#icons)
- [Picking a component](#picking-a-component)
- [Chat interfaces](#chat-interfaces)

## Use what exists

1. Check installed components (`$SHADCN info --json`) and the registry
   (`$SHADCN search @shadcn -q "..."`) before writing a styled `div`.
2. Read the component's docs first: `$SHADCN docs <component>` prints the docs, example and
   API URLs; fetch them. Guessing props from memory is the most common source of wrong code.
3. Compose: a settings page is Tabs + Card + Field controls; a dashboard is Sidebar + Card +
   Chart + Table.

## Styling

| Rule | Wrong | Right |
|---|---|---|
| Semantic tokens, never raw colours | `bg-blue-500 text-white`, `text-gray-600` | `bg-primary text-primary-foreground`, `text-muted-foreground` |
| Status colours from Badge variants or tokens | `<span className="text-emerald-600">+20%</span>` | `<Badge variant="secondary">+20%</Badge>`, `text-destructive`, or a new token (theming.md) |
| Variants before classes | `<Button className="border bg-transparent hover:bg-accent">` | `<Button variant="outline">` |
| `className` is for layout | colours or type on a Card via `className` | `className="mx-auto max-w-md"`; colour through tokens or a new `cva` variant |
| `gap-*`, never `space-x/y-*` | `space-y-4` | `flex flex-col gap-4` |
| `size-*` when width = height | `w-10 h-10` | `size-10` |
| `truncate` | `overflow-hidden text-ellipsis whitespace-nowrap` | `truncate` |
| No hand-written `dark:` colours | `bg-white dark:bg-gray-950` | `bg-background` (tokens switch with `.dark`) |
| `cn()` for conditional classes | template-literal ternaries | `cn("flex", active && "bg-muted")` |
| No `z-index` on overlays | `z-50` on Dialog, Popover, Tooltip... | nothing: they manage stacking |
| Utilities over custom animation | a hand-rolled shimmer `@keyframes` | `shimmer`, `scroll-fade` utilities (from `shadcn/tailwind.css`) |

Since September 2026 components import `cn` from the `cn` package; `lib/utils.ts`
re-exports it. Older projects with `clsx` + `tailwind-merge` keep working
(`migrate cn` converts them).

## Structure

- **Items live inside their group.** `SelectItem` and `SelectLabel` in `SelectGroup`;
  `DropdownMenuItem`, `DropdownMenuLabel` and `DropdownMenuSub` in `DropdownMenuGroup`;
  `MenubarItem` in `MenubarGroup`; `ContextMenuItem` in `ContextMenuGroup`; `CommandItem`
  in `CommandGroup`.
- **Dialog, Sheet and Drawer always have a title** (`DialogTitle`, `SheetTitle`,
  `DrawerTitle`); hide it with `className="sr-only"` if the design has none. Screen readers
  announce the dialog by it.
- **Full Card composition**: `CardHeader` / `CardTitle` / `CardDescription` /
  `CardContent` / `CardFooter`, not everything in `CardContent`.
- **Button has no `isLoading`**: `<Button disabled><Spinner data-icon="inline-start" />
  Saving...</Button>`.
- **`TabsTrigger` inside `TabsList`**, never directly in `Tabs`.
- **`Avatar` with `AvatarFallback`** for when the image fails.
- **Existing components over markup**: callouts are `Alert`; empty states `Empty`;
  dividers `Separator`; loading placeholders `Skeleton` (no `animate-pulse` divs); labels
  and pills `Badge`; a control inside an input `InputGroup` + `InputGroupAddon`.

## Icons

- Import from the project's `iconLibrary` (`lucide` is `lucide-react`, `tabler` is
  `@tabler/icons-react`, and so on). Never assume lucide; after adding a third-party item,
  swap its icon imports to the project's library.
- In a `Button`, mark the icon's side: `data-icon="inline-start"` or `"inline-end"`.
- No sizing classes on icons inside components (`size-4`, `w-4 h-4`): components size them,
  unless the user asks for a custom size.
- Pass icons as components (`icon={CheckIcon}`), not string keys into a lookup map.
- An icon-only button needs a name: `<Button size="icon" aria-label="Delete">` or an
  `sr-only` span.

## Picking a component

| Need | Use |
|---|---|
| Action | `Button` with a variant; `ButtonGroup` for related actions |
| Text, choice, toggle | `Input`, `Textarea`, `Select`, `NativeSelect`, `Combobox`, `Checkbox`, `RadioGroup`, `Switch` (settings), `Slider`, `InputOTP` |
| 2 to 7 exclusive options | `ToggleGroup` + `ToggleGroupItem`, not looped Buttons with active state |
| Dates | `Calendar`, `DatePicker` (Popover + Calendar) |
| Data display | `Table` (simple), the data-table guide (sorting, filters, pages), `Card`, `Badge`, `Avatar`, `Item`, `Kbd` |
| Navigation | `Sidebar`, `NavigationMenu`, `Breadcrumb`, `Tabs`, `Pagination` |
| Overlays | `Dialog`, `AlertDialog` (confirm destructive), `Sheet` (side panel), `Drawer` (mobile bottom), `Popover`, `HoverCard`, `Tooltip` |
| Menus | `DropdownMenu`, `ContextMenu`, `Menubar`, `Command` (palette, inside a Dialog) |
| Feedback | `Alert`, `Progress`, `Skeleton`, `Spinner`, `Empty`, toasts (bases.md) |
| Layout | `Card`, `Separator`, `Resizable`, `ScrollArea`, `Accordion`, `Collapsible`, `AspectRatio` |
| Charts | `Chart` (Recharts; charts.md) |

## Chat interfaces

shadcn/ui added chat primitives in June 2026 and Trace, Code Block and AI Elements in
October 2026: `MessageScroller` (scrolling, streaming follow, jump-to-latest), `Message`,
`Bubble`, `Attachment`, `Marker` (dividers, system notes) and `Trace` (reasoning, tool calls,
sources). Use them instead of hand-rolled bubbles or a `ResizeObserver` stick-to-bottom hook,
and read `$SHADCN docs message-scroller` before writing one: the API is young and moves.
