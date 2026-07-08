#!/usr/bin/env bash
# Generate FastAPI endpoint boilerplate (Pydantic models + CRUD router) to stdout.
#
# Usage:   scaffold-api.sh <resource_name>
# Input:   one positional arg — a singular resource name (e.g. "user", "order")
# Output:  a complete FastAPI module (models + APIRouter CRUD endpoints) on stdout;
#          redirect into a file to use it (the script emits to stdout and never
#          opens a file itself, so it cannot clobber a user's project)
# Stderr:  usage and error messages only
# Exit:    0 ok, 2 usage (missing resource / unknown flag)
#
# Examples:
#   scaffold-api.sh user > routers/user.py
#   scaffold-api.sh order | tee routers/orders.py

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: scaffold-api.sh <resource_name>

Generate FastAPI endpoint boilerplate — Pydantic Create/Update/Response models
plus an APIRouter with list/create/get/update/delete CRUD endpoints — printed to
stdout. Redirect into a module file to use it.

Arguments:
  resource_name   a singular resource name, e.g. "user" or "order"

Exit codes: 0 ok, 2 usage (missing resource / unknown flag).

Examples:
  scaffold-api.sh user > routers/user.py
  scaffold-api.sh order | tee routers/orders.py
EOF
}

# Flags first: --help short-circuits; any unknown flag is a hard usage error.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "scaffold-api.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done

RESOURCE="${1:-}"

if [[ -z "$RESOURCE" ]]; then
  echo "scaffold-api.sh: resource name required" >&2
  usage >&2
  exit 2
fi

# Convert to different cases
RESOURCE_LOWER=$(echo "$RESOURCE" | tr '[:upper:]' '[:lower:]')
RESOURCE_UPPER=$(echo "$RESOURCE" | tr '[:lower:]' '[:upper:]')
RESOURCE_TITLE=$(echo "$RESOURCE_LOWER" | sed 's/\b\(.\)/\u\1/g')
RESOURCE_PLURAL="${RESOURCE_LOWER}s"

cat << EOF
# =============================================================================
# ${RESOURCE_TITLE} Models
# =============================================================================

from pydantic import BaseModel, Field
from datetime import datetime

class ${RESOURCE_TITLE}Create(BaseModel):
    """Create ${RESOURCE_LOWER} request."""
    name: str = Field(..., min_length=1, max_length=100)
    # Add more fields

class ${RESOURCE_TITLE}Update(BaseModel):
    """Update ${RESOURCE_LOWER} request (partial)."""
    name: str | None = None
    # Add more fields

class ${RESOURCE_TITLE}Response(BaseModel):
    """${RESOURCE_TITLE} response."""
    id: int
    name: str
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


# =============================================================================
# ${RESOURCE_TITLE} Router
# =============================================================================

from fastapi import APIRouter, Depends, HTTPException
from typing import Annotated

router = APIRouter(prefix="/${RESOURCE_PLURAL}", tags=["${RESOURCE_PLURAL}"])

@router.get("/", response_model=list[${RESOURCE_TITLE}Response])
async def list_${RESOURCE_PLURAL}(
    db: DB,
    skip: int = 0,
    limit: int = 10,
):
    """List all ${RESOURCE_PLURAL}."""
    result = await db.execute(
        select(${RESOURCE_TITLE}).offset(skip).limit(limit)
    )
    return result.scalars().all()

@router.post("/", response_model=${RESOURCE_TITLE}Response, status_code=201)
async def create_${RESOURCE_LOWER}(data: ${RESOURCE_TITLE}Create, db: DB):
    """Create a new ${RESOURCE_LOWER}."""
    ${RESOURCE_LOWER} = ${RESOURCE_TITLE}(**data.model_dump())
    db.add(${RESOURCE_LOWER})
    await db.commit()
    await db.refresh(${RESOURCE_LOWER})
    return ${RESOURCE_LOWER}

@router.get("/{${RESOURCE_LOWER}_id}", response_model=${RESOURCE_TITLE}Response)
async def get_${RESOURCE_LOWER}(${RESOURCE_LOWER}_id: int, db: DB):
    """Get a ${RESOURCE_LOWER} by ID."""
    ${RESOURCE_LOWER} = await db.get(${RESOURCE_TITLE}, ${RESOURCE_LOWER}_id)
    if not ${RESOURCE_LOWER}:
        raise HTTPException(status_code=404, detail="${RESOURCE_TITLE} not found")
    return ${RESOURCE_LOWER}

@router.patch("/{${RESOURCE_LOWER}_id}", response_model=${RESOURCE_TITLE}Response)
async def update_${RESOURCE_LOWER}(
    ${RESOURCE_LOWER}_id: int,
    data: ${RESOURCE_TITLE}Update,
    db: DB,
):
    """Update a ${RESOURCE_LOWER}."""
    ${RESOURCE_LOWER} = await db.get(${RESOURCE_TITLE}, ${RESOURCE_LOWER}_id)
    if not ${RESOURCE_LOWER}:
        raise HTTPException(status_code=404, detail="${RESOURCE_TITLE} not found")

    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(${RESOURCE_LOWER}, field, value)

    await db.commit()
    await db.refresh(${RESOURCE_LOWER})
    return ${RESOURCE_LOWER}

@router.delete("/{${RESOURCE_LOWER}_id}", status_code=204)
async def delete_${RESOURCE_LOWER}(${RESOURCE_LOWER}_id: int, db: DB):
    """Delete a ${RESOURCE_LOWER}."""
    ${RESOURCE_LOWER} = await db.get(${RESOURCE_TITLE}, ${RESOURCE_LOWER}_id)
    if not ${RESOURCE_LOWER}:
        raise HTTPException(status_code=404, detail="${RESOURCE_TITLE} not found")

    await db.delete(${RESOURCE_LOWER})
    await db.commit()

# =============================================================================
# Include in main app:
# from routers.${RESOURCE_PLURAL} import router as ${RESOURCE_PLURAL}_router
# app.include_router(${RESOURCE_PLURAL}_router, prefix="/api/v1")
# =============================================================================
EOF
