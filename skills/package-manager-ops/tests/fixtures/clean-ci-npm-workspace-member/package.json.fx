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
    "build": "vite build"
  },
  "devDependencies": {
    "sass": "^1.93.2",
    "vite": "^8.0.10"
  },
  "workspaces": [
    "packages/*"
  ]
}
