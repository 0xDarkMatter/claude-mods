@import "tailwindcss";
@import "tw-animate-css";
@import "shadcn/tailwind.css";

@source "../../../apps/**/*.{ts,tsx}";

:root {
  --background: oklch(1 0 0);
}

@theme inline {
  --color-background: var(--background);
}
