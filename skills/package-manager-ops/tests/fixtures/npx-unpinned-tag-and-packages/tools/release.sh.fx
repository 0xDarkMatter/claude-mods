#!/usr/bin/env bash
npx eslint@latest .
npx --package=ts-node@10.9.2 --package=typescript ts-node scripts/build.ts
npx eslint@^9 .
npx eslint@^8 .
