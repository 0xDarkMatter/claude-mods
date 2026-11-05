{
  "name": "fixture-site",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "packageManager": "npm@11.19.0",
  "engines": {
    "node": ">=24 <25"
  },
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "typecheck": "npx tsc --noEmit",
    "prod": "npx mix --production",
    "e2e": "npx playwright test",
    "bundle": "npx fxb --out dist",
    "serve": "npx fxr serve dist"
  },
  "devDependencies": {
    "@commitlint/cli": "^19.8.1",
    "@playwright/test": "1.55.0",
    "fixture-builder": "^2.1.0",
    "fixture-runner": "^3.0.0",
    "laravel-mix": "^6.0.49",
    "sass": "^1.93.2",
    "typescript": "5.8.3",
    "vite": "^8.0.10"
  }
}
