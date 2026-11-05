#!/bin/sh
# pm-audit: ignore[npx.unpinned] one-off bootstrap, the CI image pins it
npx eslint .
