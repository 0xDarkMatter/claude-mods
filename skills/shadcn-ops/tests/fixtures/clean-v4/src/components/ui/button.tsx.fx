import { cn } from "cn"

export function Button({ className, ...props }: React.ComponentProps<"button">) {
  return <button data-slot="button" className={cn("inline-flex", className)} {...props} />
}
