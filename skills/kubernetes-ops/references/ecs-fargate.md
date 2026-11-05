# Amazon ECS on Fargate: the Choice and the Basics

This skill is about Kubernetes. ECS on Fargate is AWS's own orchestrator: serverless
containers, with no nodes to patch and no control plane to run. This file covers choosing
it and the basics that trip people. For anything deeper (ECS Express Mode, Managed
Instances, EKS Auto Mode, Karpenter, the Load Balancer Controller, ECR), use AWS's
official `aws-containers` skill (github.com/aws/agent-toolkit-for-aws,
`skills/core-skills/aws-containers`). It is maintained by AWS and current where this file
is not.

## Contents

- [ECS or Kubernetes](#ecs-or-kubernetes)
- [The building blocks](#the-building-blocks)
- [Two IAM roles](#two-iam-roles)
- [Networking](#networking)
- [Failures that look like something else](#failures-that-look-like-something-else)

## ECS or Kubernetes

| | ECS on Fargate | Kubernetes (EKS or self-managed) |
|---|---|---|
| Operations | no nodes, no control plane | you run nodes (EKS runs the control plane) |
| Portability | AWS only | any cloud, on-premises, a laptop |
| Ecosystem | AWS-native: ALB, IAM, CloudWatch, Secrets Manager | the CNCF ecosystem: Helm, operators, Gateway API |
| Learning curve | low | high |
| Fits | an AWS-committed team that wants to stop running hosts | portability, complex scheduling, an existing Kubernetes investment |

EKS can also run pods on Fargate capacity: that is Kubernetes on serverless nodes, a
different product from ECS on Fargate.

## The building blocks

- **Task definition**: the images, task-level CPU and memory (Fargate takes only valid
  pairs), the `awsvpc` network mode (mandatory on Fargate), logging, the two IAM roles, and
  `secrets` mappings from Secrets Manager or SSM Parameter Store. Values arrive as env vars
  at start; they are never baked into the image.
- **Service**: keeps N tasks running, registers them with a load balancer, deploys
  rolling or blue/green, and scales through Application Auto Scaling.
- **Capacity providers**: `FARGATE` (on-demand) and `FARGATE_SPOT` (interruptible, much
  cheaper). Run a FARGATE base with a weighted Spot layer for stateless work.

## Two IAM roles

| Role | Used by | Grants |
|---|---|---|
| **Task execution role** | the ECS agent, at launch | pull from ECR, write logs, read the `secrets` (and their KMS key) |
| **Task role** | your application, at runtime | the app's own AWS access (S3, SQS, DynamoDB ...) |

Keep them separate and least-privilege: no app permissions on the execution role, no image
pulls on the task role.

## Networking

Every task gets its own network interface, so security groups attach to the *task*. Run
tasks in private subnets. Reach AWS services through VPC endpoints (ECR, Secrets Manager,
CloudWatch Logs) rather than paying for NAT traffic. Use an ALB for HTTP(S) and an NLB for
TCP/UDP or a static IP; targets register as `ip`.

## Failures that look like something else

| Symptom | Usually |
|---|---|
| a task can't reach RDS (timeout) | the RDS security group doesn't allow the *task's* security group (reference the group, not a CIDR), or the subnet has no route |
| `CannotPullContainerError` | the execution role can't pull from ECR, or no route to ECR (no NAT, no endpoint) |
| secrets fail at start | the execution role can't read the secret or its KMS key |
| tasks killed under load | task CPU or memory too small: check Container Insights |
| Spot tasks disappear | Spot interruptions: add a FARGATE base to the capacity strategy |
| a deploy "succeeds" with a broken image | no container health check, so ECS can't tell |

Canonical docs: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html
and the ECS best-practices guide in the same set.
