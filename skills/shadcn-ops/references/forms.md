# Forms

shadcn/ui's form story is the `Field` component family plus a form library of your choice.
Facts from ui.shadcn.com/docs/forms, /forms/react-hook-form, /forms/tanstack-form,
/forms/next and /components/{field, combobox, date-picker, calendar, input} for each base,
checked 2026-11-10; layout rules adapted from the official shadcn skill's
`rules/forms.md` (shadcn-ui/ui, MIT licence).

## Contents

- [Which approach](#which-approach)
- [The Field family](#the-field-family)
- [React Hook Form](#react-hook-form)
- [TanStack Form](#tanstack-form)
- [Combobox in a form](#combobox-in-a-form)
- [Dates in a form](#dates-in-a-form)
- [File inputs](#file-inputs)
- [Server-side validation](#server-side-validation)
- [Layout rules](#layout-rules)
- [Accessibility checklist](#accessibility-checklist)

## Which approach

The docs list React Hook Form, TanStack Form and Formisch as form libraries; all three use
the same `Field` markup and only the binding differs. A separate Next.js guide builds the
same forms with `useActionState` and Server Actions (the plain-React `useActionState` card
still says "coming soon"); Server Actions themselves belong to nextjs-ops.

Validation is any Standard Schema validator. The docs' own examples use Zod 3
(`z.string().email()`, with `@hookform/resolvers` 3). The snippets below are Zod 4:
`z.email()` exists only in Zod 4, and `@hookform/resolvers` supports Zod 4 from 5.1.0. Match
the project's Zod major (`pnpm why zod`) before copying either.

The older `Form` wrapper (`FormField`, `FormItem`, `FormControl`, `FormMessage`) ships only
for the legacy `new-york` style. In a `base-*`, `radix-*` or `aria-*` project the `form`
item is an empty stub, so `add form` installs nothing: keep an existing `form.tsx` as it is,
or move that form to `Field` + the library's controller. Write new forms with `Field`, and
don't mix the two in one form.

```bash
$SHADCN add field input textarea select checkbox switch button
```

Then install the form library and validator yourself (`react-hook-form`,
`@hookform/resolvers`, `zod`, or `@tanstack/react-form`): they are new dependencies, so
they go through the 7-day cooldown and a behavioural scan (supply-chain-defense).

## The Field family

| Part | Use |
|---|---|
| `Field` | one field: label, control, help, error. `orientation="vertical"` (default), `"horizontal"` (settings rows), `"responsive"` (inside a `FieldGroup` with `@container/field-group`) |
| `FieldLabel` | the label; `htmlFor` = the control's `id` |
| `FieldDescription` | help text |
| `FieldError` | errors; `errors={[...]}` takes `{ message }` objects (Standard Schema issues fit) |
| `FieldGroup` | stacks fields; enables container queries |
| `FieldSet` + `FieldLegend` | a real `<fieldset>` for related checkboxes, radios, switches; `FieldLegend variant="label"` for label sizing |
| `FieldContent`, `FieldTitle` | label + description beside a control (switch rows) |
| `FieldSeparator` | a divider between groups |

`Field` renders `role="group"`. Invalid state needs both halves: `data-invalid` on `Field`
(styles label and help) and `aria-invalid` on the control (styles it and tells assistive
tech). Disabled: `data-disabled` on `Field`, `disabled` on the control.

## React Hook Form

Bind each control with RHF's `Controller` and render `Field` inside it:

```tsx
"use client"

import { zodResolver } from "@hookform/resolvers/zod"
import { Controller, useForm } from "react-hook-form"
import * as z from "zod"

import { Button } from "@/components/ui/button"
import { Field, FieldError, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"

const schema = z.object({
  email: z.email("Enter a valid email."),   // Zod 4; Zod 3 is z.string().email(...)
  name: z.string().min(1, "Name is required."),
})

export function InviteForm({ onInvite }: { onInvite: (v: z.infer<typeof schema>) => Promise<void> }) {
  const form = useForm<z.infer<typeof schema>>({
    resolver: zodResolver(schema),
    defaultValues: { email: "", name: "" },
  })
  return (
    <form onSubmit={form.handleSubmit(onInvite)}>
      <FieldGroup>
        <Controller
          name="email"
          control={form.control}
          render={({ field, fieldState }) => (
            <Field data-invalid={fieldState.invalid}>
              <FieldLabel htmlFor="email">Email</FieldLabel>
              <Input {...field} id="email" type="email" aria-invalid={fieldState.invalid} />
              {fieldState.invalid && <FieldError errors={[fieldState.error]} />}
            </Field>
          )}
        />
        {/* name: the same pattern */}
        <Button type="submit" disabled={form.formState.isSubmitting}>Send invite</Button>
      </FieldGroup>
    </form>
  )
}
```

For `Select`, `Checkbox`, `Switch` and `RadioGroup`, put `aria-invalid` on the trigger or
item and wire `value` / `onValueChange` (or `checked` / `onCheckedChange`) by hand; the
spread `{...field}` only fits text inputs. React Aria differs: `isInvalid` goes on the
`Select` (or `Combobox`) root, and values arrive through `onChange`. The Select API itself
differs by base (bases.md).

## TanStack Form

```tsx
const form = useForm({
  defaultValues: { email: "" },
  validators: { onSubmit: schema },        // or onChange / onBlur
  onSubmit: async ({ value }) => save(value),
})

<form onSubmit={(e) => { e.preventDefault(); form.handleSubmit() }}>
  <form.Field
    name="email"
    children={(field) => {
      const isInvalid = field.state.meta.isTouched && !field.state.meta.isValid
      return (
        <Field data-invalid={isInvalid}>
          <FieldLabel htmlFor={field.name}>Email</FieldLabel>
          <Input id={field.name} value={field.state.value} onBlur={field.handleBlur}
                 onChange={(e) => field.handleChange(e.target.value)} aria-invalid={isInvalid} />
          {isInvalid && <FieldError errors={field.state.meta.errors} />}
        </Field>
      )
    }}
  />
</form>
```

## Combobox in a form

Base UI and Radix projects share one Combobox, built on Base UI (on Radix it adds
`@base-ui/react`); React Aria has its own. Bind it with RHF's `Controller` (TanStack Form:
`field.state.value` and `field.handleChange` in the same places):

```tsx
<Controller
  name="framework"
  control={form.control}
  render={({ field, fieldState }) => (
    <Field data-invalid={fieldState.invalid}>
      <FieldLabel htmlFor="framework">Framework</FieldLabel>
      <Combobox items={frameworks} value={field.value} onValueChange={field.onChange}>
        <ComboboxInput id="framework" placeholder="Pick one" onBlur={field.onBlur}
                       aria-invalid={fieldState.invalid} />
        <ComboboxContent>
          <ComboboxEmpty>No match.</ComboboxEmpty>
          <ComboboxList>
            {(item) => <ComboboxItem key={item} value={item}>{item}</ComboboxItem>}
          </ComboboxList>
        </ComboboxContent>
      </Combobox>
      {fieldState.invalid && <FieldError errors={[fieldState.error]} />}
    </Field>
  )}
/>
```

| | Base UI and Radix | React Aria |
|---|---|---|
| Value and change | `value` / `onValueChange`; a cleared single value is `null` | `value` / `onChange` |
| Items | `items` on `Combobox`, `ComboboxItem value` (objects need `itemToStringValue`) | `ComboboxItem id` (and `textValue` when children are JSX) |
| Multiple | `multiple`, default `[]`; `ComboboxChips` holding `ComboboxValue` (the chips) and `ComboboxChipsInput` | `selectionMode="multiple"`; `ComboboxChips` holding `ComboboxChipList` and `ComboboxChipsInput` |
| Invalid | `aria-invalid` on `ComboboxInput` (or `ComboboxChipsInput`) | `isInvalid` on `Combobox` |
| Empty state | `ComboboxEmpty` inside `ComboboxContent` | `allowsEmptyCollection` + `renderEmptyState` on `ComboboxList` |

Give the schema the value the component emits: `z.string()` with a `null` default for a
single pick (the schema then rejects the empty state), `z.array(z.string()).min(1)` with a
`[]` default for multiple.

## Dates in a form

There is no `DatePicker` component: it is `Popover` + `Calendar`. Base UI and Radix render
React DayPicker and work in JS `Date`; React Aria renders its own Calendar and works in
`CalendarDate` from `@internationalized/date`.

```tsx
<Controller
  name="dueDate"
  control={form.control}
  render={({ field, fieldState }) => (
    <Field data-invalid={fieldState.invalid}>
      <FieldLabel htmlFor="due-date">Due date</FieldLabel>
      <Popover>
        {/* Radix: <PopoverTrigger asChild><Button ...>...</Button></PopoverTrigger> */}
        <PopoverTrigger render={<Button id="due-date" variant="outline" aria-invalid={fieldState.invalid} />}>
          {field.value ? format(field.value, "PPP") : "Pick a date"}
        </PopoverTrigger>
        <PopoverContent className="w-auto p-0">
          <Calendar mode="single" selected={field.value} onSelect={field.onChange} />
        </PopoverContent>
      </Popover>
      {fieldState.invalid && <FieldError errors={[fieldState.error]} />}
    </Field>
  )}
/>
```

| | Base UI and Radix (React DayPicker) | React Aria |
|---|---|---|
| Single | `mode="single" selected onSelect`; value `Date` or `undefined`; schema `z.date()` | `<Calendar value onChange>`; value `CalendarDate` or `null` |
| Range | `mode="range"`; value `{ from, to }` (`DateRange`); schema `z.object({ from: z.date(), to: z.date() })` | `<RangeCalendar value onChange>`; value `{ start, end }` |
| Trigger | `PopoverTrigger` with `render` (Base UI) or `asChild` (Radix), beside `PopoverContent` | `PopoverTrigger` wraps the `Button` and a `Popover` holding the `Calendar` |
| Display | `date-fns` `format` | `date.toDate(getLocalTimeZone())`, then `toLocaleDateString` |

Timezones: send a date-only value as `YYYY-MM-DD` (`format(d, "yyyy-MM-dd")` or
`CalendarDate.toString()`), never `toISOString()`, which can shift the day; if the
DayPicker Calendar highlights the day before, set its `timeZone` prop on the client.

## File inputs

shadcn/ui has no upload or dropzone component: a file field is `Input type="file"` inside a
`Field`. A file input's value can't be set from code, so leave it uncontrolled: RHF's
`register` (which yields a `FileList`), or an `onChange` with no `value`.

```tsx
const { errors } = form.formState

<Field data-invalid={!!errors.avatar}>
  <FieldLabel htmlFor="avatar">Avatar</FieldLabel>
  <Input id="avatar" type="file" accept="image/png,image/jpeg"
         aria-invalid={!!errors.avatar} {...form.register("avatar")} />
  <FieldDescription>PNG or JPEG, up to 2 MB.</FieldDescription>
  {errors.avatar && <FieldError errors={[errors.avatar]} />}
</Field>
```

TanStack Form: `onChange={(e) => field.handleChange(e.target.files?.[0] ?? null)}` and no
`value` prop. Check the count, size and type in the schema and again on the server: `accept`
is a hint to the file picker, not a check. Show chosen files, progress and removal with
`Item` or `Attachment` if you need them, and keep the upload itself in your own code.

## Server-side validation

Client validation is for the user; the server validates again with the same schema and
returns field errors. Map them back with RHF's `form.setError("email", { message })` (or
TanStack Form's field meta) so they render in the same `FieldError`. Next.js Server Actions,
their auth checks and `useActionState` belong to nextjs-ops.

## Layout rules

- Fields go in `FieldGroup` + `Field`, never a `div` with `space-y-*` or a `grid gap-*` of
  bare labels.
- Option sets of 2 to 7 choices: `ToggleGroup` (labelled with `FieldTitle` +
  `aria-labelledby`), not a row of Buttons with manual active state.
- Related checkboxes or radios: `FieldSet` + `FieldLegend` + `FieldDescription`, not a `div`
  with a heading.
- A button or icon inside an input: `InputGroup` with `InputGroupInput` (or
  `InputGroupTextarea`) and `InputGroupAddon`; a raw `Input` inside `InputGroup`, or an
  absolutely positioned Button, is wrong.
- Settings pages: `Field orientation="horizontal"`; a visually hidden label is
  `FieldLabel className="sr-only"`, never no label.
- Long forms: split with `FieldSeparator` or `FieldSet`s; put the primary action last and
  disable it while submitting.

## Accessibility checklist

- Every control has a label tied by `htmlFor`/`id` (placeholder text is not a label).
- Errors are text in `FieldError`, not colour alone, and appear next to the field.
- On a failed submit, move focus to the first invalid field (RHF's `shouldFocusError` does
  this by default).
- Required fields say so in text. Full audits (WCAG 2.2, axe, screen readers) belong to
  a11y-ops.
