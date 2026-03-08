# gRPC Patterns

## Table of Contents

- [Protocol Buffers (proto3)](#protocol-buffers-proto3)
- [Service Definitions](#service-definitions)
- [gRPC in Go](#grpc-in-go)
- [gRPC in Rust](#grpc-in-rust)
- [Interceptors and Middleware](#interceptors-and-middleware)
- [Error Handling](#error-handling)
- [Deadlines and Cancellation](#deadlines-and-cancellation)
- [Health Checking](#health-checking)
- [Reflection and CLI Tools](#reflection-and-cli-tools)
- [gRPC-Web and Connect](#grpc-web-and-connect)
- [When gRPC Beats REST](#when-grpc-beats-rest)

---

## Protocol Buffers (proto3)

### Basic Syntax

```protobuf
syntax = "proto3";

package myapi.v1;

option go_package = "github.com/myorg/myapi/gen/go/myapi/v1";

// Messages
message User {
  string id = 1;
  string name = 2;
  string email = 3;
  UserRole role = 4;
  google.protobuf.Timestamp created_at = 5;
  optional string bio = 6;           // Explicit optional (presence tracking)
  repeated string tags = 7;          // List
  map<string, string> metadata = 8;  // Key-value map
}

// Enums (always start with 0 = UNSPECIFIED)
enum UserRole {
  USER_ROLE_UNSPECIFIED = 0;
  USER_ROLE_ADMIN = 1;
  USER_ROLE_MEMBER = 2;
  USER_ROLE_VIEWER = 3;
}

// Oneof (mutually exclusive fields)
message Notification {
  string id = 1;
  oneof channel {
    EmailNotification email = 2;
    SmsNotification sms = 3;
    PushNotification push = 4;
  }
}

message EmailNotification {
  string subject = 1;
  string body = 2;
}
message SmsNotification {
  string phone = 1;
  string text = 2;
}
message PushNotification {
  string title = 1;
  string body = 2;
}
```

### Well-Known Types

```protobuf
import "google/protobuf/timestamp.proto";   // Timestamp
import "google/protobuf/duration.proto";     // Duration
import "google/protobuf/empty.proto";        // Empty (no fields)
import "google/protobuf/wrappers.proto";     // Nullable primitives
import "google/protobuf/struct.proto";       // Dynamic JSON-like
import "google/protobuf/field_mask.proto";   // Partial updates
import "google/protobuf/any.proto";          // Type-erased message

message UpdateUserRequest {
  string id = 1;
  User user = 2;
  google.protobuf.FieldMask update_mask = 3;  // Which fields to update
}
```

### Proto Design Rules

| Rule | Example |
|------|---------|
| Field numbers are forever | Never reuse a deleted field number |
| Enums start at 0 = UNSPECIFIED | `USER_ROLE_UNSPECIFIED = 0` |
| Use `optional` for presence | Distinguish "not set" from default value |
| Prefix enum values with type name | `USER_ROLE_ADMIN` not `ADMIN` |
| Package = `org.service.v1` | Enables API versioning |
| Avoid `float`/`double` for money | Use `int64` cents or `string` |
| Use FieldMask for partial updates | Explicit about which fields changed |
| Reserved deleted fields | `reserved 5, 6; reserved "old_field";` |

## Service Definitions

### Four Communication Patterns

```protobuf
service UserService {
  // Unary - simple request/response
  rpc GetUser(GetUserRequest) returns (GetUserResponse);

  // Server streaming - server sends multiple responses
  rpc ListUsers(ListUsersRequest) returns (stream User);

  // Client streaming - client sends multiple requests
  rpc UploadUserPhotos(stream UploadPhotoRequest) returns (UploadSummary);

  // Bidirectional streaming - both sides stream
  rpc Chat(stream ChatMessage) returns (stream ChatMessage);
}

message GetUserRequest {
  string id = 1;
}

message GetUserResponse {
  User user = 1;
}

message ListUsersRequest {
  int32 page_size = 1;
  string page_token = 2;
  string filter = 3;
}
```

### Request/Response Patterns

```protobuf
// Pagination (AIP-158 style)
message ListUsersRequest {
  int32 page_size = 1;            // Max items per page
  string page_token = 2;          // Opaque token from previous response
}

message ListUsersResponse {
  repeated User users = 1;
  string next_page_token = 2;     // Empty = no more pages
  int32 total_size = 3;           // Optional total count
}

// Batch operations
message BatchGetUsersRequest {
  repeated string ids = 1;        // Max 100
}

message BatchGetUsersResponse {
  repeated User users = 1;
}
```

## gRPC in Go

### Server Implementation

```go
package main

import (
    "context"
    "log"
    "net"

    "google.golang.org/grpc"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"

    pb "github.com/myorg/myapi/gen/go/myapi/v1"
)

type userServer struct {
    pb.UnimplementedUserServiceServer  // Forward compatibility
    store UserStore
}

func (s *userServer) GetUser(ctx context.Context, req *pb.GetUserRequest) (*pb.GetUserResponse, error) {
    if req.GetId() == "" {
        return nil, status.Error(codes.InvalidArgument, "id is required")
    }

    user, err := s.store.Get(ctx, req.GetId())
    if err != nil {
        if errors.Is(err, ErrNotFound) {
            return nil, status.Errorf(codes.NotFound, "user %s not found", req.GetId())
        }
        return nil, status.Errorf(codes.Internal, "failed to get user: %v", err)
    }

    return &pb.GetUserResponse{User: user}, nil
}

// Server streaming
func (s *userServer) ListUsers(req *pb.ListUsersRequest, stream pb.UserService_ListUsersServer) error {
    users, err := s.store.List(stream.Context(), req)
    if err != nil {
        return status.Errorf(codes.Internal, "failed to list users: %v", err)
    }

    for _, user := range users {
        if err := stream.Send(user); err != nil {
            return err
        }
    }
    return nil
}

func main() {
    lis, err := net.Listen("tcp", ":50051")
    if err != nil {
        log.Fatalf("failed to listen: %v", err)
    }

    server := grpc.NewServer(
        grpc.UnaryInterceptor(loggingInterceptor),
        grpc.ChainUnaryInterceptor(authInterceptor, loggingInterceptor),
    )
    pb.RegisterUserServiceServer(server, &userServer{store: NewUserStore()})

    log.Println("gRPC server listening on :50051")
    if err := server.Serve(lis); err != nil {
        log.Fatalf("failed to serve: %v", err)
    }
}
```

### Client Usage (Go)

```go
func main() {
    conn, err := grpc.Dial("localhost:50051",
        grpc.WithTransportCredentials(insecure.NewCredentials()),
        grpc.WithUnaryInterceptor(retryInterceptor),
    )
    if err != nil {
        log.Fatalf("failed to connect: %v", err)
    }
    defer conn.Close()

    client := pb.NewUserServiceClient(conn)

    // Unary call with deadline
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    resp, err := client.GetUser(ctx, &pb.GetUserRequest{Id: "user-123"})
    if err != nil {
        st, ok := status.FromError(err)
        if ok {
            log.Printf("gRPC error: code=%s, message=%s", st.Code(), st.Message())
        }
        return
    }
    log.Printf("User: %s", resp.GetUser().GetName())

    // Server streaming
    stream, err := client.ListUsers(ctx, &pb.ListUsersRequest{PageSize: 100})
    if err != nil {
        log.Fatal(err)
    }
    for {
        user, err := stream.Recv()
        if err == io.EOF {
            break
        }
        if err != nil {
            log.Fatal(err)
        }
        log.Printf("User: %s", user.GetName())
    }
}
```

## gRPC in Rust

### Server with Tonic

```toml
# Cargo.toml
[dependencies]
tonic = "0.12"
prost = "0.13"
tokio = { version = "1", features = ["full"] }

[build-dependencies]
tonic-build = "0.12"
```

```rust
// build.rs
fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::compile_protos("proto/myapi/v1/user.proto")?;
    Ok(())
}
```

```rust
use tonic::{Request, Response, Status};

pub mod myapi {
    pub mod v1 {
        tonic::include_proto!("myapi.v1");
    }
}
use myapi::v1::user_service_server::{UserService, UserServiceServer};
use myapi::v1::{GetUserRequest, GetUserResponse, User};

#[derive(Default)]
pub struct MyUserService;

#[tonic::async_trait]
impl UserService for MyUserService {
    async fn get_user(
        &self,
        request: Request<GetUserRequest>,
    ) -> Result<Response<GetUserResponse>, Status> {
        let req = request.into_inner();

        if req.id.is_empty() {
            return Err(Status::invalid_argument("id is required"));
        }

        // Fetch user from store...
        let user = User {
            id: req.id,
            name: "Alice".into(),
            email: "alice@example.com".into(),
            ..Default::default()
        };

        Ok(Response::new(GetUserResponse { user: Some(user) }))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let addr = "[::1]:50051".parse()?;
    let service = MyUserService::default();

    tonic::transport::Server::builder()
        .add_service(UserServiceServer::new(service))
        .serve(addr)
        .await?;

    Ok(())
}
```

### Client with Tonic

```rust
use myapi::v1::user_service_client::UserServiceClient;
use myapi::v1::GetUserRequest;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut client = UserServiceClient::connect("http://[::1]:50051").await?;

    let request = tonic::Request::new(GetUserRequest {
        id: "user-123".into(),
    });

    let response = client.get_user(request).await?;
    println!("User: {:?}", response.into_inner().user);

    Ok(())
}
```

## Interceptors and Middleware

### Go Unary Interceptor

```go
func loggingInterceptor(
    ctx context.Context,
    req interface{},
    info *grpc.UnaryServerInfo,
    handler grpc.UnaryHandler,
) (interface{}, error) {
    start := time.Now()

    // Extract metadata
    md, _ := metadata.FromIncomingContext(ctx)
    requestID := md.Get("x-request-id")

    resp, err := handler(ctx, req)

    st, _ := status.FromError(err)
    log.Printf("method=%s duration=%s status=%s request_id=%v",
        info.FullMethod, time.Since(start), st.Code(), requestID)

    return resp, err
}

func authInterceptor(
    ctx context.Context,
    req interface{},
    info *grpc.UnaryServerInfo,
    handler grpc.UnaryHandler,
) (interface{}, error) {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok {
        return nil, status.Error(codes.Unauthenticated, "no metadata")
    }

    tokens := md.Get("authorization")
    if len(tokens) == 0 {
        return nil, status.Error(codes.Unauthenticated, "no token")
    }

    claims, err := validateToken(tokens[0])
    if err != nil {
        return nil, status.Error(codes.Unauthenticated, "invalid token")
    }

    // Add claims to context
    ctx = context.WithValue(ctx, claimsKey, claims)
    return handler(ctx, req)
}
```

### Chaining Interceptors

```go
server := grpc.NewServer(
    grpc.ChainUnaryInterceptor(
        recoveryInterceptor,    // Panic recovery (outermost)
        loggingInterceptor,     // Request logging
        metricsInterceptor,     // Prometheus metrics
        authInterceptor,        // Authentication
        validationInterceptor,  // Request validation
    ),
    grpc.ChainStreamInterceptor(
        streamLoggingInterceptor,
        streamAuthInterceptor,
    ),
)
```

## Error Handling

### gRPC Status Codes

| Code | Name | Use When |
|------|------|----------|
| 0 | OK | Success |
| 1 | CANCELLED | Client cancelled |
| 2 | UNKNOWN | Unknown error (avoid - be specific) |
| 3 | INVALID_ARGUMENT | Bad request (validation) |
| 4 | DEADLINE_EXCEEDED | Timeout |
| 5 | NOT_FOUND | Resource doesn't exist |
| 6 | ALREADY_EXISTS | Conflict (duplicate) |
| 7 | PERMISSION_DENIED | Authorized but not allowed |
| 8 | RESOURCE_EXHAUSTED | Rate limit, quota |
| 9 | FAILED_PRECONDITION | State not ready (e.g., non-empty directory) |
| 10 | ABORTED | Concurrency conflict (retry) |
| 11 | OUT_OF_RANGE | Seek past end |
| 12 | UNIMPLEMENTED | Method not implemented |
| 13 | INTERNAL | Internal server error |
| 14 | UNAVAILABLE | Service down (retry with backoff) |
| 16 | UNAUTHENTICATED | No valid credentials |

### Rich Error Details (Go)

```go
import (
    "google.golang.org/genproto/googleapis/rpc/errdetails"
    "google.golang.org/grpc/status"
)

func (s *server) CreateUser(ctx context.Context, req *pb.CreateUserRequest) (*pb.CreateUserResponse, error) {
    // Validation with rich error details
    var violations []*errdetails.BadRequest_FieldViolation

    if req.GetEmail() == "" {
        violations = append(violations, &errdetails.BadRequest_FieldViolation{
            Field:       "email",
            Description: "Email is required",
        })
    }
    if len(req.GetName()) < 2 {
        violations = append(violations, &errdetails.BadRequest_FieldViolation{
            Field:       "name",
            Description: "Name must be at least 2 characters",
        })
    }

    if len(violations) > 0 {
        st := status.New(codes.InvalidArgument, "validation failed")
        br := &errdetails.BadRequest{FieldViolations: violations}
        st, _ = st.WithDetails(br)
        return nil, st.Err()
    }

    // ... proceed
}
```

### Mapping gRPC to HTTP Status Codes

| gRPC Code | HTTP Status |
|-----------|-------------|
| OK | 200 |
| INVALID_ARGUMENT | 400 |
| UNAUTHENTICATED | 401 |
| PERMISSION_DENIED | 403 |
| NOT_FOUND | 404 |
| ALREADY_EXISTS | 409 |
| RESOURCE_EXHAUSTED | 429 |
| CANCELLED | 499 |
| INTERNAL | 500 |
| UNIMPLEMENTED | 501 |
| UNAVAILABLE | 503 |
| DEADLINE_EXCEEDED | 504 |

## Deadlines and Cancellation

### Setting Deadlines (Go Client)

```go
// Always set deadlines - never leave RPCs unbounded
ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel()

resp, err := client.GetUser(ctx, &pb.GetUserRequest{Id: "user-123"})
if err != nil {
    st, _ := status.FromError(err)
    if st.Code() == codes.DeadlineExceeded {
        // Handle timeout - maybe retry with longer deadline
    }
}
```

### Propagating Deadlines

Deadlines automatically propagate through the call chain. If service A calls service B with a 5s deadline, and A takes 2s, B gets the remaining 3s.

```go
// Server-side: check remaining time
deadline, ok := ctx.Deadline()
if ok {
    remaining := time.Until(deadline)
    if remaining < 100*time.Millisecond {
        return nil, status.Error(codes.DeadlineExceeded, "insufficient time remaining")
    }
}
```

## Health Checking

### Standard Health Protocol

```protobuf
// Built-in: grpc.health.v1.Health
service Health {
  rpc Check(HealthCheckRequest) returns (HealthCheckResponse);
  rpc Watch(HealthCheckRequest) returns (stream HealthCheckResponse);
}

message HealthCheckRequest {
  string service = 1;  // Empty = overall health
}

message HealthCheckResponse {
  enum ServingStatus {
    UNKNOWN = 0;
    SERVING = 1;
    NOT_SERVING = 2;
    SERVICE_UNKNOWN = 3;
  }
  ServingStatus status = 1;
}
```

### Go Implementation

```go
import "google.golang.org/grpc/health"
import healthpb "google.golang.org/grpc/health/grpc_health_v1"

server := grpc.NewServer()
healthServer := health.NewServer()
healthpb.RegisterHealthServer(server, healthServer)

// Set status
healthServer.SetServingStatus("myapi.v1.UserService", healthpb.HealthCheckResponse_SERVING)

// Kubernetes uses grpc_health_probe
// livenessProbe:
//   exec:
//     command: ["/bin/grpc_health_probe", "-addr=:50051"]
```

## Reflection and CLI Tools

### Enable Reflection

```go
import "google.golang.org/grpc/reflection"

server := grpc.NewServer()
reflection.Register(server)  // Enable for dev/staging
```

### grpcurl (like curl for gRPC)

```bash
# List services
grpcurl -plaintext localhost:50051 list

# Describe a service
grpcurl -plaintext localhost:50051 describe myapi.v1.UserService

# Call a method
grpcurl -plaintext -d '{"id": "user-123"}' \
  localhost:50051 myapi.v1.UserService/GetUser

# Server streaming
grpcurl -plaintext -d '{"page_size": 10}' \
  localhost:50051 myapi.v1.UserService/ListUsers

# With metadata (headers)
grpcurl -plaintext \
  -H 'authorization: Bearer token123' \
  -d '{"id": "user-123"}' \
  localhost:50051 myapi.v1.UserService/GetUser
```

### buf (Modern Protobuf Tooling)

```bash
# Lint proto files
buf lint

# Detect breaking changes
buf breaking --against '.git#branch=main'

# Generate code
buf generate

# buf.yaml
version: v2
lint:
  use:
    - STANDARD
breaking:
  use:
    - WIRE_JSON
```

## gRPC-Web and Connect

### The Browser Problem

Browsers cannot use gRPC natively (no HTTP/2 trailers, no bidirectional streaming). Solutions:

| Solution | Approach | Streaming | Ecosystem |
|----------|----------|-----------|-----------|
| gRPC-Web | Proxy (Envoy) translates | Server-streaming only | Google official |
| Connect | Native HTTP/1.1 + HTTP/2 | All patterns via HTTP/2 | Buf (connectrpc.com) |
| gRPC-Gateway | Generate REST from proto | None (REST) | grpc-ecosystem |

### Connect (Recommended for New Projects)

```protobuf
// Same .proto files - no changes needed
service UserService {
  rpc GetUser(GetUserRequest) returns (GetUserResponse);
}
```

```typescript
// TypeScript client (works in browser natively)
import { createClient } from "@connectrpc/connect";
import { createConnectTransport } from "@connectrpc/connect-web";
import { UserService } from "./gen/myapi/v1/user_connect";

const transport = createConnectTransport({
  baseUrl: "https://api.example.com",
});

const client = createClient(UserService, transport);

const response = await client.getUser({ id: "user-123" });
console.log(response.user?.name);
```

Connect supports three protocols simultaneously:
- **Connect protocol**: Simple HTTP POST with JSON or Protobuf
- **gRPC protocol**: Standard gRPC (HTTP/2)
- **gRPC-Web protocol**: Browser-compatible gRPC

## When gRPC Beats REST

### Use gRPC When

- Internal service-to-service communication
- Performance matters (10x smaller payloads, 7x faster serialization)
- You need streaming (logs, real-time feeds, file uploads)
- You want a strict contract between services
- Polyglot environment (generate clients for any language)
- Bidirectional communication

### Use REST When

- Public API consumed by third-party developers
- Browser clients are primary (unless using Connect)
- You need HTTP caching (CDN, browser cache)
- Team is more familiar with REST
- Simple CRUD with few relationships
- Webhooks are a primary integration pattern

### Hybrid Approach

Many production systems use both:
- gRPC for internal microservice communication
- REST/GraphQL for external-facing APIs
- gRPC-Gateway or Connect to expose gRPC services as REST

```
[Browser] --REST/GraphQL--> [API Gateway] --gRPC--> [User Service]
                                          --gRPC--> [Order Service]
                                          --gRPC--> [Payment Service]
```
