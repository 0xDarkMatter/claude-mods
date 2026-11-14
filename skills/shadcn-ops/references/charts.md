# Charts

`Chart` is a thin layer over Recharts v3: you write Recharts components and wrap them in
shadcn's container, tooltip and legend so they take the theme. Facts from
ui.shadcn.com/docs/components/chart, checked 2026-11-10.

## Install and shape

```bash
$SHADCN add chart          # adds components/ui/chart.tsx and the recharts dependency
```

```tsx
"use client"
import { Bar, BarChart, CartesianGrid, XAxis } from "recharts"
import { ChartContainer, ChartLegend, ChartLegendContent, ChartTooltip, ChartTooltipContent, type ChartConfig } from "@/components/ui/chart"

const chartConfig = {
  revenue: { label: "Revenue", color: "var(--chart-1)" },
  refunds: { label: "Refunds", color: "var(--chart-2)" },
} satisfies ChartConfig

export function RevenueChart({ data }: { data: { month: string; revenue: number; refunds: number }[] }) {
  return (
    <ChartContainer config={chartConfig} className="min-h-[240px] w-full">
      <BarChart accessibilityLayer data={data}>
        <CartesianGrid vertical={false} />
        <XAxis dataKey="month" tickLine={false} axisLine={false} />
        <ChartTooltip content={<ChartTooltipContent />} />
        <ChartLegend content={<ChartLegendContent />} />
        <Bar dataKey="revenue" fill="var(--color-revenue)" radius={4} />
        <Bar dataKey="refunds" fill="var(--color-refunds)" radius={4} />
      </BarChart>
    </ChartContainer>
  )
}
```

## Rules

- **`ChartContainer` needs a height**: `min-h-[...]`, a fixed height or `aspect-*`, or the
  responsive container measures zero on first render and draws nothing.
- **Colours come from the config.** Each key gets a `color` (a token such as
  `var(--chart-1)`, or hex/hsl/oklch), exposed as `--color-<key>`; reference that in the
  series (`fill="var(--color-revenue)"`). The five `--chart-1..5` tokens live in the theme
  for light and dark.
- **Recharts v3 changes** from v2-era code: `var(--chart-1)` instead of
  `hsl(var(--chart-1))`; `ChartTooltip`'s `defaultIndex` only sets the initial tooltip (keep
  persistent active shapes in your own state); remove `layout` from `<Bar>` when the parent
  `BarChart` already sets it.
- **`accessibilityLayer`** on the chart adds keyboard navigation and screen-reader support.
  A chart still needs a text alternative for its key number or trend (a caption, a KPI card
  beside it, or a table toggle).
- **KPI cards** are `Card` + `CardDescription` (label) + a large `CardTitle` number with
  `tabular-nums` + a `Badge` for the change; no raw green/red text (composition-rules.md).
- Client component: charts measure the DOM, so the file needs `"use client"` in an RSC
  project; fetch the data in the server parent and pass it down.
