{
  "name": "@workspace/ui",
  "version": "0.0.0",
  "type": "module",
  "private": true,
  "dependencies": {
    "@base-ui/react": "^1.9.0",
    "cn": "^0.5.2",
    "react": "^19.3.1",
    "react-dom": "^19.3.1"
  },
  "devDependencies": {
    "shadcn": "4.23.0",
    "tailwindcss": "^4.3.5",
    "tw-animate-css": "^1.4.0"
  },
  "exports": {
    "./globals.css": "./src/styles/globals.css",
    "./lib/*": "./src/lib/*.ts",
    "./components/*": "./src/components/*.tsx",
    "./hooks/*": "./src/hooks/*.ts"
  }
}
