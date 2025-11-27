---
name: data-processing
description: "Process JSON with jq and YAML/TOML with yq. Filter, transform, query structured data efficiently. Triggers on: parse JSON, extract from YAML, query config, Docker Compose, K8s manifests, GitHub Actions workflows, package.json, filter data."
---

# Data Processing

## Purpose
Query, filter, and transform structured data (JSON, YAML, TOML) efficiently from the command line.

## Tools

| Tool | Command | Use For |
|------|---------|---------|
| jq | `jq '.key' file.json` | JSON processing |
| yq | `yq '.key' file.yaml` | YAML/TOML processing |

## Usage Examples

### JSON with jq

```bash
# Extract single field
jq '.name' package.json

# Extract nested field
jq '.dependencies | keys' package.json

# Filter array
jq '.users[] | select(.active == true)' data.json

# Transform structure
jq '.items[] | {id, name}' data.json

# Pretty print
jq '.' response.json

# Compact output
jq -c '.results[]' data.json
```

### YAML with yq

```bash
# Extract field from YAML
yq '.services | keys' docker-compose.yml

# Get all container images
yq '.services[].image' docker-compose.yml

# Extract GitHub Actions job names
yq '.jobs | keys' .github/workflows/ci.yml

# Get K8s resource names
yq '.metadata.name' deployment.yaml

# Convert YAML to JSON
yq -o json '.' config.yaml
```

## When to Use

- Reading package.json dependencies
- Parsing Docker Compose configurations
- Analyzing Kubernetes manifests
- Processing GitHub Actions workflows
- Extracting data from API responses
- Filtering large JSON datasets
