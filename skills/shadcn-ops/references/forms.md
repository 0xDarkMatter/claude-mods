# Forms

shadcn/ui's form story is the `Field` component family plus a form library of your choice.
Facts from ui.shadcn.com/docs/forms, /forms/react-hook-form, /forms/tanstack-form and
/components/field, checked 2026-11-10; layout rules adapted from the official shadcn skill's
`rules/forms.md` (shadcn-ui/ui, MIT licence).

## Contents

- [Which approach](#which-approach)
- [The Field family](#the-field-family)
- [React Hook Form](#react-hook-form)
- [TanStack Form](#tanstack-form)
- [Server-side validation](#server-side-validation)
- [Layout rules](#layout-rules)
- [Accessibility checklist](#accessibility-checklist)

## Which approach

The docs list React Hook Form, TanStack Form and Formisch as supported libraries (React's
`useActionState` is marked "coming soon"). All three use the same `Field` markup; only the
binding differs. Validation is any Standard Schema validator; the docs use Zod 4.

The older `Form` wrapper (`FormField`, `FormItem`, `FormControl`, `FormMessage`) still ships
in every base's registry, so existing forms built on it keep working. Write new forms with
`Field` + the library's own controller, as the current guides do; don't mix the two in one
form.

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
  email: z.email("Enter a valid email."),
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
spread `{...field}` only fits text inputs. The Select API itself differs by base
(bases.md).

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
