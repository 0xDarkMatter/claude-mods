{
  "$schema": "https://ui.shadcn.com/schema.json",
  "style": "base-nova",
  "rsc": false,
  "tsx": true,
  "tailwind": {
    "config": "",
    "css": "src/index.css",
    "baseColor": "neutral",
    "cssVariables": true
  },
  "iconLibrary": "lucide",
  "aliases": {
    "components": "@/components",
    "utils": "@/lib/utils",
    "ui": "@/components/ui",
    "lib": "@/lib",
    "hooks": "@/hooks"
  },
  "registries": {
    "@private": {
      "url": "https://registry.example.com/r/{name}.json",
      "headers": {
        "Authorization": "token ${GITHUB_TOKEN}",
        "X-Auth-Token": "bearer ${REGISTRY_TOKEN}",
        "X-Api-Key": "BASIC ${REGISTRY_BASIC}"
      }
    }
  }
}
