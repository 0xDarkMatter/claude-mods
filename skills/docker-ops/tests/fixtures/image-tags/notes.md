# Fixture notes

Only fenced code counts:

```dockerfile
FROM golang:1.27-trixie AS build
FROM build AS test
```

This FROM ignored:1.0 line is prose, not code.

```yaml
spec:
  containers:
    - name: web
      image: registry.k8s.io/pause:3.10
```
