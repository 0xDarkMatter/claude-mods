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

## jq Basics

### Selection and Navigation

```bash
# Extract single field
jq '.name' package.json

# Extract nested field
jq '.scripts.build' package.json

# Extract from array
jq '.dependencies[0]' package.json

# Extract multiple fields
jq '{name, version}' package.json

# Navigate deeply nested
jq '.data.users[0].profile.email' response.json
```

### Array Operations

```bash
# Get all array elements
jq '.users[]' data.json

# Get specific index
jq '.users[0]' data.json

# Slice array
jq '.users[0:3]' data.json           # First 3 elements
jq '.users[-2:]' data.json           # Last 2 elements

# Array length
jq '.users | length' data.json

# Get array of specific field
jq '.users[].name' data.json

# Wrap results in array
jq '[.users[].name]' data.json
```

### Filtering with select

```bash
# Filter by condition
jq '.users[] | select(.active == true)' data.json

# Multiple conditions
jq '.users[] | select(.age > 21 and .status == "active")' data.json

# String contains
jq '.users[] | select(.email | contains("@gmail"))' data.json

# Regex match
jq '.users[] | select(.email | test("@(gmail|yahoo)"))' data.json

# Not null check
jq '.users[] | select(.profile != null)' data.json
```

### Transformation with map

```bash
# Transform each element
jq '.users | map({id, name})' data.json

# Add computed field
jq '.users | map(. + {full_name: (.first + " " + .last)})' data.json

# Filter and transform
jq '.users | map(select(.active)) | map(.email)' data.json

# map_values for objects
jq '.config | map_values(. * 2)' data.json
```

### Object Manipulation

```bash
# Add/update field
jq '.version = "2.0.0"' package.json

# Delete field
jq 'del(.devDependencies)' package.json

# Rename key
jq '.dependencies | to_entries | map(.key |= gsub("@"; ""))' package.json

# Merge objects
jq '. + {newField: "value"}' data.json

# Update nested field
jq '.scripts.test = "jest --coverage"' package.json

# Conditional update
jq 'if .version == "1.0.0" then .version = "1.0.1" else . end' package.json
```

### Aggregation

```bash
# Count
jq '.users | length' data.json

# Sum
jq '[.items[].price] | add' data.json

# Min/Max
jq '[.scores[]] | min' data.json
jq '[.scores[]] | max' data.json

# Average
jq '[.scores[]] | add / length' data.json

# Group by
jq 'group_by(.category) | map({category: .[0].category, count: length})' data.json

# Unique values
jq '[.users[].role] | unique' data.json

# Sort
jq '.users | sort_by(.created_at)' data.json
jq '.users | sort_by(.name) | reverse' data.json
```

### Output Formatting

```bash
# Pretty print
jq '.' response.json

# Compact output (single line)
jq -c '.results[]' data.json

# Raw strings (no quotes)
jq -r '.name' package.json

# Tab-separated output
jq -r '.users[] | [.id, .name, .email] | @tsv' data.json

# CSV output
jq -r '.users[] | [.id, .name, .email] | @csv' data.json

# URI encoding
jq -r '.query | @uri' data.json
```

## yq for YAML/TOML

### Basic YAML Operations

```bash
# Extract field
yq '.name' config.yaml

# Extract nested
yq '.services.web.image' docker-compose.yml

# List all keys
yq 'keys' config.yaml

# Get array element
yq '.volumes[0]' docker-compose.yml
```

### Docker Compose Queries

```bash
# List all service names
yq '.services | keys' docker-compose.yml

# Get all images
yq '.services[].image' docker-compose.yml

# Get environment variables for a service
yq '.services.web.environment' docker-compose.yml

# Find services with specific image
yq '.services | to_entries | map(select(.value.image | contains("nginx")))' docker-compose.yml
```

### Kubernetes Manifests

```bash
# Get resource name
yq '.metadata.name' deployment.yaml

# Get container images
yq '.spec.template.spec.containers[].image' deployment.yaml

# Get all labels
yq '.metadata.labels' deployment.yaml

# Multi-document YAML (---)
yq eval-all '.metadata.name' manifests.yaml
```

### GitHub Actions Workflows

```bash
# List all jobs
yq '.jobs | keys' .github/workflows/ci.yml

# Get steps for a job
yq '.jobs.build.steps[].name' .github/workflows/ci.yml

# Find jobs using specific action
yq '.jobs[].steps[] | select(.uses | contains("actions/checkout"))' .github/workflows/ci.yml

# Get all environment variables
yq '.env' .github/workflows/ci.yml
```

### TOML Processing

```bash
# Read TOML file
yq -p toml '.dependencies' Cargo.toml

# Convert TOML to JSON
yq -p toml -o json '.' config.toml

# Extract pyproject.toml dependencies
yq -p toml '.project.dependencies[]' pyproject.toml
```

### YAML Modification

```bash
# Update value (in-place)
yq -i '.version = "2.0.0"' config.yaml

# Add new field
yq -i '.new_field = "value"' config.yaml

# Delete field
yq -i 'del(.old_field)' config.yaml

# Add to array
yq -i '.tags += ["new-tag"]' config.yaml

# Merge YAML files
yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' base.yaml override.yaml
```

## Common Config Files

### package.json

```bash
# List all dependencies
jq '.dependencies | keys' package.json

# Get all scripts
jq '.scripts' package.json

# Find outdated patterns
jq '.dependencies | to_entries | map(select(.value | startswith("^")))' package.json

# Extract dev dependencies
jq '.devDependencies | keys | .[]' package.json
```

### tsconfig.json

```bash
# Get compiler options
jq '.compilerOptions' tsconfig.json

# Check strict mode
jq '.compilerOptions.strict' tsconfig.json

# List paths aliases
jq '.compilerOptions.paths' tsconfig.json
```

### ESLint/Prettier

```bash
# Get enabled rules
jq '.rules | to_entries | map(select(.value != "off"))' .eslintrc.json

# Check prettier options
jq '.' .prettierrc.json
```

## Advanced Patterns

### Combining jq with Shell

```bash
# Process multiple files
for f in *.json; do jq '.name' "$f"; done

# Pipeline with other tools
curl -s https://api.github.com/users/octocat | jq '.login'

# Assign to variable
VERSION=$(jq -r '.version' package.json)

# Conditional logic
jq -e '.errors | length == 0' response.json && echo "Success"
```

### Complex Transformations

```bash
# Flatten nested structure
jq '[.categories[].items[]] | flatten' data.json

# Reshape data
jq '.users | map({(.id | tostring): .name}) | add' data.json

# Pivot data
jq 'group_by(.date) | map({date: .[0].date, values: map(.value)})' data.json

# Join arrays
jq -s '.[0] + .[1]' file1.json file2.json
```

## Quick Reference

| Task | jq | yq |
|------|----|----|
| Get field | `jq '.key'` | `yq '.key'` |
| Array element | `jq '.[0]'` | `yq '.[0]'` |
| Filter array | `jq '.[] \| select(.x)'` | `yq '.[] \| select(.x)'` |
| Transform | `jq 'map(.x)'` | `yq 'map(.x)'` |
| Count | `jq 'length'` | `yq 'length'` |
| Keys | `jq 'keys'` | `yq 'keys'` |
| Pretty print | `jq '.'` | `yq '.'` |
| Compact | `jq -c` | `yq -o json -I0` |
| Raw output | `jq -r` | `yq -r` |
| In-place edit | - | `yq -i` |

## When to Use

- Reading package.json dependencies
- Parsing Docker Compose configurations
- Analyzing Kubernetes manifests
- Processing GitHub Actions workflows
- Extracting data from API responses
- Filtering large JSON datasets
- Config file manipulation
- Data format conversion
