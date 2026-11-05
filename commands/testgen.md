---
description: "Alias for /test-engineering write (one release only). Generate tests for a target, each proved able to fail."
---

# /testgen (alias)

`testgen` was merged into the **test-engineering** skill. This alias keeps `/testgen` working
for one release and will then be removed.

Invoke the `test-engineering` skill in **write** mode with the user's arguments:

```
/test-engineering write $ARGUMENTS
```

Follow that skill's write-mode procedure (references/write.md): failure list first, tests named
for the bugs they prevent, and each test proved with `scripts/mutate.mjs --prove` or marked
`unverified`. Tell the user once that `/test-engineering write` is the new name.
