# JSON Output Schemas

Complete JSON response patterns for CLI tools.

## List Response (Paginated)

```json
{
  "data": [
    {"id": "item-001", "name": "First Item", "status": "ACTIVE"},
    {"id": "item-002", "name": "Second Item", "status": "DRAFT"}
  ],
  "meta": {
    "count": 2,
    "total": 156,
    "page": 1,
    "per_page": 20,
    "has_more": true,
    "next_cursor": "eyJpZCI6Iml0ZW0tMDAyIn0="
  }
}
```

## List Response (Simple)

For tools where pagination metadata isn't relevant:

```json
{
  "data": [
    {"id": "1", "name": "Item 1"},
    {"id": "2", "name": "Item 2"}
  ]
}
```

Or minimal array form:

```json
[
  {"id": "1", "name": "Item 1"},
  {"id": "2", "name": "Item 2"}
]
```

## Single Item Response

```json
{
  "data": {
    "id": "item-001",
    "name": "Example Item",
    "description": "A sample item",
    "status": "ACTIVE",
    "metadata": {
      "created_by": "user-123",
      "tags": ["important", "urgent"]
    },
    "created_at": "2025-01-15T10:30:00Z",
    "updated_at": "2025-01-15T14:22:00Z"
  }
}
```

## Mutation Response

```json
{
  "data": {
    "id": "item-003",
    "name": "New Item",
    "status": "DRAFT",
    "created_at": "2025-01-27T09:15:00Z"
  },
  "meta": {
    "action": "created"
  }
}
```

## Field Conventions

| Type | JSON Type | Format | Example |
|------|-----------|--------|---------|
| Identifiers | string | Any format | `"id": "item_abc123"` |
| Timestamps | string | ISO 8601 with timezone | `"created_at": "2025-01-15T10:30:00Z"` |
| Dates (no time) | string | ISO 8601 date | `"due_date": "2025-02-15"` |
| Money | number | Decimal, not cents | `"total": 1250.50` |
| Currency | string | ISO 4217 code | `"currency": "USD"` |
| Booleans | boolean | true/false | `"is_active": true` |
| Nulls | null | Explicit, not omitted | `"deleted_at": null` |
| Enums | string | UPPER_SNAKE_CASE | `"status": "IN_PROGRESS"` |
| Arrays | array | Even if empty | `"tags": []` |
| Nested objects | object | Embedded, not ID-only | `"user": {"id": "...", "name": "..."}` |

## Error Response

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Invalid input provided",
    "details": {
      "field": "amount",
      "reason": "must be positive",
      "value": -50
    }
  }
}
```

The `details` object is optional and contains context-specific information.

## Pagination in Response

```json
{
  "data": [...],
  "meta": {
    "count": 20,
    "total": 156,
    "page": 1,
    "per_page": 20,
    "has_more": true,
    "next_cursor": "eyJpZCI6ImFiYzEyMyJ9"
  }
}
```
