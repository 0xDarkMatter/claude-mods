# API Project Templates

Complete scaffolds for backend API projects across languages and frameworks.

## FastAPI (Python)

### Full Directory Tree

```
my-api/
├── src/
│   └── my_api/
│       ├── __init__.py
│       ├── main.py
│       ├── config.py
│       ├── database.py
│       ├── dependencies.py
│       ├── routers/
│       │   ├── __init__.py
│       │   ├── health.py
│       │   └── users.py
│       ├── models/
│       │   ├── __init__.py
│       │   └── user.py
│       ├── schemas/
│       │   ├── __init__.py
│       │   └── user.py
│       └── services/
│           ├── __init__.py
│           └── user.py
├── alembic/
│   ├── alembic.ini
│   ├── env.py
│   └── versions/
│       └── .gitkeep
├── tests/
│   ├── __init__.py
│   ├── conftest.py
│   ├── test_health.py
│   └── test_users.py
├── pyproject.toml
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── .gitignore
└── .dockerignore
```

### main.py

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from my_api.config import settings
from my_api.database import engine
from my_api.routers import health, users


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    yield
    # Shutdown
    await engine.dispose()


app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(users.router, prefix="/api/v1")
```

### config.py

```python
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    app_name: str = "My API"
    debug: bool = False
    database_url: str = "postgresql+asyncpg://user:pass@localhost:5432/mydb"
    cors_origins: list[str] = ["http://localhost:3000"]
    secret_key: str = "change-me-in-production"

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


settings = Settings()
```

### database.py

```python
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase

from my_api.config import settings

engine = create_async_engine(settings.database_url, echo=settings.debug)
async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


async def get_db() -> AsyncSession:
    async with async_session() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
```

### models/user.py

```python
from datetime import datetime
from sqlalchemy import String, DateTime, func
from sqlalchemy.orm import Mapped, mapped_column

from my_api.database import Base


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
```

### schemas/user.py

```python
from datetime import datetime
from pydantic import BaseModel, EmailStr


class UserCreate(BaseModel):
    email: EmailStr
    name: str


class UserUpdate(BaseModel):
    email: EmailStr | None = None
    name: str | None = None


class UserResponse(BaseModel):
    id: int
    email: str
    name: str
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class UserListResponse(BaseModel):
    items: list[UserResponse]
    total: int
```

### routers/users.py

```python
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from my_api.database import get_db
from my_api.schemas.user import UserCreate, UserUpdate, UserResponse, UserListResponse
from my_api.services.user import UserService

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/", response_model=UserListResponse)
async def list_users(
    skip: int = Query(0, ge=0),
    limit: int = Query(20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
):
    service = UserService(db)
    users, total = await service.list_users(skip=skip, limit=limit)
    return UserListResponse(items=users, total=total)


@router.post("/", response_model=UserResponse, status_code=201)
async def create_user(
    user_in: UserCreate,
    db: AsyncSession = Depends(get_db),
):
    service = UserService(db)
    return await service.create_user(user_in)


@router.get("/{user_id}", response_model=UserResponse)
async def get_user(user_id: int, db: AsyncSession = Depends(get_db)):
    service = UserService(db)
    user = await service.get_user(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user


@router.patch("/{user_id}", response_model=UserResponse)
async def update_user(
    user_id: int,
    user_in: UserUpdate,
    db: AsyncSession = Depends(get_db),
):
    service = UserService(db)
    user = await service.update_user(user_id, user_in)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user


@router.delete("/{user_id}", status_code=204)
async def delete_user(user_id: int, db: AsyncSession = Depends(get_db)):
    service = UserService(db)
    deleted = await service.delete_user(user_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="User not found")
```

### routers/health.py

```python
from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from my_api.database import get_db

router = APIRouter(tags=["health"])


@router.get("/health")
async def health_check(db: AsyncSession = Depends(get_db)):
    await db.execute(text("SELECT 1"))
    return {"status": "healthy"}
```

### services/user.py

```python
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from my_api.models.user import User
from my_api.schemas.user import UserCreate, UserUpdate


class UserService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def list_users(
        self, skip: int = 0, limit: int = 20
    ) -> tuple[list[User], int]:
        total_query = select(func.count()).select_from(User)
        total = (await self.db.execute(total_query)).scalar_one()

        query = select(User).offset(skip).limit(limit)
        result = await self.db.execute(query)
        return list(result.scalars().all()), total

    async def get_user(self, user_id: int) -> User | None:
        return await self.db.get(User, user_id)

    async def create_user(self, user_in: UserCreate) -> User:
        user = User(**user_in.model_dump())
        self.db.add(user)
        await self.db.flush()
        await self.db.refresh(user)
        return user

    async def update_user(self, user_id: int, user_in: UserUpdate) -> User | None:
        user = await self.db.get(User, user_id)
        if not user:
            return None
        for field, value in user_in.model_dump(exclude_unset=True).items():
            setattr(user, field, value)
        await self.db.flush()
        await self.db.refresh(user)
        return user

    async def delete_user(self, user_id: int) -> bool:
        user = await self.db.get(User, user_id)
        if not user:
            return False
        await self.db.delete(user)
        return True
```

### tests/conftest.py

```python
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker

from my_api.database import Base, get_db
from my_api.main import app

TEST_DATABASE_URL = "sqlite+aiosqlite:///./test.db"

engine = create_async_engine(TEST_DATABASE_URL)
TestSession = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


@pytest.fixture(autouse=True)
async def setup_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


@pytest.fixture
async def db():
    async with TestSession() as session:
        yield session


@pytest.fixture
async def client(db):
    async def override_get_db():
        yield db

    app.dependency_overrides[get_db] = override_get_db
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac
    app.dependency_overrides.clear()
```

### tests/test_users.py

```python
import pytest


@pytest.mark.asyncio
async def test_create_user(client):
    response = await client.post(
        "/api/v1/users/",
        json={"email": "test@example.com", "name": "Test User"},
    )
    assert response.status_code == 201
    data = response.json()
    assert data["email"] == "test@example.com"
    assert data["name"] == "Test User"
    assert "id" in data


@pytest.mark.asyncio
async def test_list_users(client):
    await client.post(
        "/api/v1/users/",
        json={"email": "user1@example.com", "name": "User 1"},
    )
    response = await client.get("/api/v1/users/")
    assert response.status_code == 200
    data = response.json()
    assert data["total"] >= 1
    assert len(data["items"]) >= 1


@pytest.mark.asyncio
async def test_get_user_not_found(client):
    response = await client.get("/api/v1/users/999")
    assert response.status_code == 404
```

### Environment and Docker

**.env.example:**

```env
APP_NAME=My API
DEBUG=false
DATABASE_URL=postgresql+asyncpg://user:password@localhost:5432/mydb
SECRET_KEY=change-me
CORS_ORIGINS=["http://localhost:3000"]
```

**Dockerfile:**

```dockerfile
# Build stage
FROM python:3.12-slim AS builder

WORKDIR /app
RUN pip install uv

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY src/ src/

# Runtime stage
FROM python:3.12-slim

WORKDIR /app
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/src /app/src

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

CMD ["uvicorn", "my_api.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**docker-compose.yml:**

```yaml
services:
  api:
    build: .
    ports:
      - "8000:8000"
    env_file: .env
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password
      POSTGRES_DB: mydb
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U user -d mydb"]
      interval: 5s
      timeout: 3s
      retries: 5

volumes:
  pgdata:
```

---

## Express / Fastify (Node.js)

### Full Directory Tree

```
my-api/
├── src/
│   ├── index.ts
│   ├── app.ts
│   ├── config.ts
│   ├── database.ts
│   ├── middleware/
│   │   ├── auth.ts
│   │   ├── error-handler.ts
│   │   └── request-logger.ts
│   ├── routes/
│   │   ├── health.ts
│   │   └── users.ts
│   ├── services/
│   │   └── user.service.ts
│   └── types/
│       └── index.ts
├── prisma/
│   └── schema.prisma
├── tests/
│   ├── setup.ts
│   └── routes/
│       └── users.test.ts
├── package.json
├── tsconfig.json
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── .gitignore
└── .dockerignore
```

### src/index.ts

```typescript
import { app } from './app';
import { config } from './config';

const start = async () => {
  try {
    await app.listen({ port: config.port, host: '0.0.0.0' });
    console.log(`Server running on port ${config.port}`);
  } catch (err) {
    console.error(err);
    process.exit(1);
  }
};

start();
```

### src/app.ts (Fastify)

```typescript
import Fastify from 'fastify';
import cors from '@fastify/cors';
import { healthRoutes } from './routes/health';
import { userRoutes } from './routes/users';
import { errorHandler } from './middleware/error-handler';

export const app = Fastify({ logger: true });

app.register(cors, { origin: true });
app.setErrorHandler(errorHandler);

app.register(healthRoutes);
app.register(userRoutes, { prefix: '/api/v1' });
```

### src/config.ts

```typescript
import { z } from 'zod';

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
  PORT: z.coerce.number().default(3000),
  DATABASE_URL: z.string().url(),
  JWT_SECRET: z.string().min(32),
});

export const config = envSchema.parse(process.env);
export type Config = z.infer<typeof envSchema>;
```

### src/routes/users.ts (Fastify)

```typescript
import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { UserService } from '../services/user.service';

const createUserSchema = z.object({
  email: z.string().email(),
  name: z.string().min(1).max(100),
});

export async function userRoutes(app: FastifyInstance) {
  const userService = new UserService();

  app.get('/users', async (request, reply) => {
    const { skip = 0, limit = 20 } = request.query as Record<string, number>;
    const result = await userService.list(skip, limit);
    return result;
  });

  app.post('/users', async (request, reply) => {
    const body = createUserSchema.parse(request.body);
    const user = await userService.create(body);
    return reply.status(201).send(user);
  });

  app.get('/users/:id', async (request, reply) => {
    const { id } = request.params as { id: string };
    const user = await userService.findById(id);
    if (!user) return reply.status(404).send({ message: 'User not found' });
    return user;
  });
}
```

### prisma/schema.prisma

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model User {
  id        String   @id @default(cuid())
  email     String   @unique
  name      String
  createdAt DateTime @default(now()) @map("created_at")
  updatedAt DateTime @updatedAt @map("updated_at")

  @@map("users")
}
```

### src/services/user.service.ts

```typescript
import { PrismaClient, User } from '@prisma/client';

const prisma = new PrismaClient();

interface CreateUserInput {
  email: string;
  name: string;
}

export class UserService {
  async list(skip = 0, limit = 20): Promise<{ items: User[]; total: number }> {
    const [items, total] = await Promise.all([
      prisma.user.findMany({ skip, take: limit, orderBy: { createdAt: 'desc' } }),
      prisma.user.count(),
    ]);
    return { items, total };
  }

  async findById(id: string): Promise<User | null> {
    return prisma.user.findUnique({ where: { id } });
  }

  async create(data: CreateUserInput): Promise<User> {
    return prisma.user.create({ data });
  }

  async update(id: string, data: Partial<CreateUserInput>): Promise<User | null> {
    try {
      return await prisma.user.update({ where: { id }, data });
    } catch {
      return null;
    }
  }

  async delete(id: string): Promise<boolean> {
    try {
      await prisma.user.delete({ where: { id } });
      return true;
    } catch {
      return false;
    }
  }
}
```

### tests/routes/users.test.ts

```typescript
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { app } from '../../src/app';

describe('User routes', () => {
  beforeAll(async () => {
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
  });

  it('should create a user', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/v1/users',
      payload: { email: 'test@example.com', name: 'Test User' },
    });
    expect(response.statusCode).toBe(201);
    const body = response.json();
    expect(body.email).toBe('test@example.com');
  });

  it('should list users', async () => {
    const response = await app.inject({
      method: 'GET',
      url: '/api/v1/users',
    });
    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.items).toBeDefined();
    expect(body.total).toBeGreaterThanOrEqual(0);
  });
});
```

### Dockerfile (Node.js)

```dockerfile
# Build stage
FROM node:20-slim AS builder

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

COPY prisma ./prisma
RUN npx prisma generate

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Runtime stage
FROM node:20-slim

WORKDIR /app
RUN apt-get update -y && apt-get install -y openssl && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/prisma ./prisma
COPY package.json ./

ENV NODE_ENV=production
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s \
    CMD node -e "fetch('http://localhost:3000/health').then(r => r.ok ? process.exit(0) : process.exit(1))"

CMD ["node", "dist/index.js"]
```

---

## Gin (Go)

### Full Directory Tree

```
my-api/
├── cmd/
│   └── server/
│       └── main.go
├── internal/
│   ├── config/
│   │   └── config.go
│   ├── database/
│   │   └── database.go
│   ├── handlers/
│   │   ├── health.go
│   │   └── user.go
│   ├── middleware/
│   │   ├── cors.go
│   │   └── logger.go
│   ├── models/
│   │   └── user.go
│   └── repository/
│       └── user.go
├── migrations/
│   ├── 001_create_users.up.sql
│   └── 001_create_users.down.sql
├── tests/
│   └── user_test.go
├── go.mod
├── go.sum
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── .gitignore
└── Makefile
```

### cmd/server/main.go

```go
package main

import (
	"log"
	"os"

	"github.com/gin-gonic/gin"
	"github.com/user/my-api/internal/config"
	"github.com/user/my-api/internal/database"
	"github.com/user/my-api/internal/handlers"
	"github.com/user/my-api/internal/middleware"
)

func main() {
	cfg := config.Load()

	db, err := database.Connect(cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("failed to connect to database: %v", err)
	}
	defer db.Close()

	r := gin.Default()
	r.Use(middleware.CORS())

	r.GET("/health", handlers.Health(db))

	v1 := r.Group("/api/v1")
	{
		userHandler := handlers.NewUserHandler(db)
		v1.GET("/users", userHandler.List)
		v1.POST("/users", userHandler.Create)
		v1.GET("/users/:id", userHandler.Get)
		v1.PATCH("/users/:id", userHandler.Update)
		v1.DELETE("/users/:id", userHandler.Delete)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = cfg.Port
	}
	log.Printf("Server starting on :%s", port)
	log.Fatal(r.Run(":" + port))
}
```

### internal/config/config.go

```go
package config

import "os"

type Config struct {
	Port        string
	DatabaseURL string
	JWTSecret   string
}

func Load() *Config {
	return &Config{
		Port:        getEnv("PORT", "8080"),
		DatabaseURL: getEnv("DATABASE_URL", "postgres://user:pass@localhost:5432/mydb?sslmode=disable"),
		JWTSecret:   getEnv("JWT_SECRET", "change-me"),
	}
}

func getEnv(key, fallback string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return fallback
}
```

### internal/handlers/user.go

```go
package handlers

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/jmoiron/sqlx"
	"github.com/user/my-api/internal/models"
	"github.com/user/my-api/internal/repository"
)

type UserHandler struct {
	repo *repository.UserRepo
}

func NewUserHandler(db *sqlx.DB) *UserHandler {
	return &UserHandler{repo: repository.NewUserRepo(db)}
}

func (h *UserHandler) List(c *gin.Context) {
	skip, _ := strconv.Atoi(c.DefaultQuery("skip", "0"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))

	users, total, err := h.repo.List(c.Request.Context(), skip, limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to list users"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": users, "total": total})
}

func (h *UserHandler) Create(c *gin.Context) {
	var input models.CreateUserInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	user, err := h.repo.Create(c.Request.Context(), input)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create user"})
		return
	}
	c.JSON(http.StatusCreated, user)
}

func (h *UserHandler) Get(c *gin.Context) {
	id := c.Param("id")
	user, err := h.repo.FindByID(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}
	c.JSON(http.StatusOK, user)
}

func (h *UserHandler) Update(c *gin.Context) {
	id := c.Param("id")
	var input models.UpdateUserInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	user, err := h.repo.Update(c.Request.Context(), id, input)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}
	c.JSON(http.StatusOK, user)
}

func (h *UserHandler) Delete(c *gin.Context) {
	id := c.Param("id")
	if err := h.repo.Delete(c.Request.Context(), id); err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}
	c.Status(http.StatusNoContent)
}
```

### internal/models/user.go

```go
package models

import "time"

type User struct {
	ID        string    `db:"id" json:"id"`
	Email     string    `db:"email" json:"email"`
	Name      string    `db:"name" json:"name"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

type CreateUserInput struct {
	Email string `json:"email" binding:"required,email"`
	Name  string `json:"name" binding:"required,min=1,max=100"`
}

type UpdateUserInput struct {
	Email *string `json:"email,omitempty" binding:"omitempty,email"`
	Name  *string `json:"name,omitempty" binding:"omitempty,min=1,max=100"`
}
```

### Dockerfile (Go)

```dockerfile
# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /server ./cmd/server

# Runtime stage
FROM alpine:3.19

RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /server .

ENV GIN_MODE=release
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["./server"]
```

---

## Axum (Rust)

### Full Directory Tree

```
my-api/
├── src/
│   ├── main.rs
│   ├── config.rs
│   ├── database.rs
│   ├── error.rs
│   ├── handlers/
│   │   ├── mod.rs
│   │   ├── health.rs
│   │   └── user.rs
│   ├── models/
│   │   ├── mod.rs
│   │   └── user.rs
│   └── routes.rs
├── migrations/
│   └── 001_create_users.sql
├── tests/
│   ├── common/
│   │   └── mod.rs
│   └── user_tests.rs
├── Cargo.toml
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── .gitignore
└── rust-toolchain.toml
```

### src/main.rs

```rust
use std::net::SocketAddr;

use tokio::net::TcpListener;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

mod config;
mod database;
mod error;
mod handlers;
mod models;
mod routes;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(tracing_subscriber::fmt::layer())
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let config = config::Config::from_env()?;
    let pool = database::connect(&config.database_url).await?;

    sqlx::migrate!("./migrations").run(&pool).await?;

    let app = routes::create_router(pool);

    let addr = SocketAddr::from(([0, 0, 0, 0], config.port));
    tracing::info!("Listening on {}", addr);
    let listener = TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}
```

### src/config.rs

```rust
use anyhow::Result;

pub struct Config {
    pub port: u16,
    pub database_url: String,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        dotenvy::dotenv().ok();

        Ok(Self {
            port: std::env::var("PORT")
                .unwrap_or_else(|_| "8080".to_string())
                .parse()?,
            database_url: std::env::var("DATABASE_URL")?,
        })
    }
}
```

### src/routes.rs

```rust
use axum::{
    routing::{get, post},
    Router,
};
use sqlx::PgPool;
use tower_http::cors::CorsLayer;

use crate::handlers::{health, user};

pub fn create_router(pool: PgPool) -> Router {
    let api = Router::new()
        .route("/users", get(user::list).post(user::create))
        .route(
            "/users/{id}",
            get(user::get_by_id)
                .patch(user::update)
                .delete(user::delete),
        );

    Router::new()
        .route("/health", get(health::check))
        .nest("/api/v1", api)
        .layer(CorsLayer::permissive())
        .with_state(pool)
}
```

### src/handlers/user.rs

```rust
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use sqlx::PgPool;

use crate::error::AppError;
use crate::models::user::{CreateUser, UpdateUser, User, UserListParams};

pub async fn list(
    State(pool): State<PgPool>,
    Query(params): Query<UserListParams>,
) -> Result<Json<serde_json::Value>, AppError> {
    let skip = params.skip.unwrap_or(0) as i64;
    let limit = params.limit.unwrap_or(20) as i64;

    let users = sqlx::query_as!(User, "SELECT * FROM users ORDER BY created_at DESC LIMIT $1 OFFSET $2", limit, skip)
        .fetch_all(&pool)
        .await?;

    let total: i64 = sqlx::query_scalar!("SELECT COUNT(*) FROM users")
        .fetch_one(&pool)
        .await?
        .unwrap_or(0);

    Ok(Json(serde_json::json!({ "items": users, "total": total })))
}

pub async fn create(
    State(pool): State<PgPool>,
    Json(input): Json<CreateUser>,
) -> Result<(StatusCode, Json<User>), AppError> {
    let user = sqlx::query_as!(
        User,
        "INSERT INTO users (email, name) VALUES ($1, $2) RETURNING *",
        input.email,
        input.name,
    )
    .fetch_one(&pool)
    .await?;

    Ok((StatusCode::CREATED, Json(user)))
}

pub async fn get_by_id(
    State(pool): State<PgPool>,
    Path(id): Path<i32>,
) -> Result<Json<User>, AppError> {
    let user = sqlx::query_as!(User, "SELECT * FROM users WHERE id = $1", id)
        .fetch_optional(&pool)
        .await?
        .ok_or(AppError::NotFound)?;

    Ok(Json(user))
}

pub async fn update(
    State(pool): State<PgPool>,
    Path(id): Path<i32>,
    Json(input): Json<UpdateUser>,
) -> Result<Json<User>, AppError> {
    let user = sqlx::query_as!(
        User,
        r#"UPDATE users SET
            email = COALESCE($1, email),
            name = COALESCE($2, name),
            updated_at = NOW()
        WHERE id = $3 RETURNING *"#,
        input.email,
        input.name,
        id,
    )
    .fetch_optional(&pool)
    .await?
    .ok_or(AppError::NotFound)?;

    Ok(Json(user))
}

pub async fn delete(
    State(pool): State<PgPool>,
    Path(id): Path<i32>,
) -> Result<StatusCode, AppError> {
    let result = sqlx::query!("DELETE FROM users WHERE id = $1", id)
        .execute(&pool)
        .await?;

    if result.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}
```

### src/error.rs

```rust
use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};

pub enum AppError {
    NotFound,
    Internal(anyhow::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            AppError::NotFound => (StatusCode::NOT_FOUND, "Not found".to_string()),
            AppError::Internal(err) => {
                tracing::error!("Internal error: {:?}", err);
                (StatusCode::INTERNAL_SERVER_ERROR, "Internal server error".to_string())
            }
        };
        (status, Json(serde_json::json!({ "error": message }))).into_response()
    }
}

impl From<sqlx::Error> for AppError {
    fn from(err: sqlx::Error) -> Self {
        AppError::Internal(err.into())
    }
}

impl From<anyhow::Error> for AppError {
    fn from(err: anyhow::Error) -> Self {
        AppError::Internal(err)
    }
}
```

### Cargo.toml

```toml
[package]
name = "my-api"
version = "0.1.0"
edition = "2021"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "macros", "migrate", "chrono"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tower-http = { version = "0.5", features = ["cors"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
anyhow = "1"
dotenvy = "0.15"
chrono = { version = "0.4", features = ["serde"] }

[dev-dependencies]
reqwest = { version = "0.12", features = ["json"] }
```

### Dockerfile (Rust)

```dockerfile
# Build stage
FROM rust:1.77-slim AS builder

WORKDIR /app
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src

COPY src ./src
COPY migrations ./migrations
RUN touch src/main.rs && cargo build --release

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates libssl3 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /app/target/release/my-api .
COPY --from=builder /app/migrations ./migrations

ENV RUST_LOG=info
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s \
    CMD curl -f http://localhost:8080/health || exit 1

CMD ["./my-api"]
```
