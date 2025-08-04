# Build Your Own Nitric Plugin Library - Phase 2: Add Lambda Functions

This is phase 2 of a 3-part tutorial. In this phase, you'll add Lambda support to create a platform that supports both storage and compute.

## Prerequisites

- Completed [Phase 1](Tutorial-Phase1-S3.md) with S3 plugin
- Docker installed (for Lambda container support)

## What You'll Learn

- Container-based Lambda deployment
- Automatic ECR repository management
- EventBridge scheduling integration
- Cross-plugin permissions (S3 ↔ Lambda)

## Step 1: Add the Lambda Plugin Structure

Starting from your Phase 1 repository:

```bash
# Create Lambda plugin structure
mkdir -p aws-lambda/module
```

## Step 2: Create the Lambda Manifest

```yaml
# aws-lambda/manifest.yaml
name: "aws-lambda"
type: "resource"
description: "AWS Lambda function with container support"
deployment:
  terraform: "module/"
properties:
  timeout:
    type: "number"
    description: "Function timeout in seconds"
    default: 30
  memory:
    type: "number"
    description: "Memory allocation in MB"
    default: 512
  ephemeral_storage:
    type: "number"
    description: "Ephemeral storage in MB"
    default: 512
  architecture:
    type: "string"
    description: "Processor architecture"
    default: "x86_64"
  function_url_auth_type:
    type: "string"
    description: "Authorization type for function URL"
    default: "NONE"
  environment:
    type: "object"
    description: "Additional environment variables"
    default: {}
```

## Step 3: Create Lambda Terraform

This implementation handles containers, ECR, and scheduling:

```hcl
# aws-lambda/module/main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

# Process cron expressions for EventBridge scheduling
locals {
  # Convert standard cron to AWS CloudWatch format
  split_cron_expression = {
    for key, schedule in var.nitric.schedules : key => split(" ", schedule.cron_expression)
  }

  transformed_cron_expression = {
    for key, fields in local.split_cron_expression : key => [
      for i, field in fields : 
        (i == 4 && fields[2] == "*" && field == "*") ? "?" : field
    ]
  }

  convert_cron_to_aws = {
    for key, schedule in var.nitric.schedules : key => {
      cron_expression = schedule.cron_expression
      path           = schedule.path
      aws_cron       = "cron(${join(" ", local.transformed_cron_expression[key])} *)"
    }
  }

  lambda_name = "${var.nitric.stack_id}-${var.nitric.name}"
}

# Create ECR repository for container images
resource "aws_ecr_repository" "repo" {
  name = var.nitric.name
}

data "aws_ecr_authorization_token" "ecr_auth" {
}

# Get the Docker image provided by Nitric
data "docker_image" "latest" {
  name = var.nitric.image_id
}

# Tag image for ECR
resource "docker_tag" "tag" {
  source_image = length(data.docker_image.latest.repo_digest) > 0 ? data.docker_image.latest.repo_digest : data.docker_image.latest.id
  target_image = aws_ecr_repository.repo.repository_url
}

# Push image to ECR
resource "docker_registry_image" "push" {
  name = aws_ecr_repository.repo.repository_url
  auth_config {
    address  = data.aws_ecr_authorization_token.ecr_auth.proxy_endpoint
    username = data.aws_ecr_authorization_token.ecr_auth.user_name
    password = data.aws_ecr_authorization_token.ecr_auth.password
  }
  triggers = {
    source_image_id = docker_tag.tag.source_image_id
  }
}

# Attach basic execution role
resource "aws_iam_role_policy_attachment" "basic-execution" {
  role       = var.nitric.identities["aws:iam:role"].role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Create Lambda function using container image
resource "aws_lambda_function" "function" {
  function_name = local.lambda_name
  role          = var.nitric.identities["aws:iam:role"].role.arn
  image_uri     = "${aws_ecr_repository.repo.repository_url}@${docker_registry_image.push.sha256_digest}"
  package_type  = "Image"
  timeout       = var.timeout
  memory_size   = var.memory
  
  ephemeral_storage {
    size = var.ephemeral_storage
  }
  
  environment {
    variables = merge(var.environment, var.nitric.env, {
      NITRIC_STACK_ID = var.nitric.stack_id
    })
  }

  architectures = [var.architecture]
  
  depends_on = [docker_registry_image.push]
}

# Create function URL for HTTP access
resource "aws_lambda_function_url" "endpoint" {
  function_name      = aws_lambda_function.function.function_name
  authorization_type = var.function_url_auth_type
  invoke_mode        = "RESPONSE_STREAM"
}

# IAM role for EventBridge scheduler
resource "aws_iam_role" "role" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "scheduler.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "role_policy" {
  role = aws_iam_role.role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = "lambda:InvokeFunction",
        Resource = aws_lambda_function.function.arn
      }
    ]
  })
}

# Create EventBridge schedules for each cron job
resource "aws_scheduler_schedule" "schedule" {
  for_each = var.nitric.schedules
  
  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = local.convert_cron_to_aws[each.key].aws_cron

  target {
    arn      = aws_lambda_function.function.arn
    role_arn = aws_iam_role.role.arn

    input = jsonencode({
        "path" = each.value.path
    })
  }
}
```

## Step 4: Define Lambda Variables

```hcl
# aws-lambda/module/variables.tf

variable "nitric" {
  description = "Nitric resource configuration"
  type = object({
    name     = string
    stack_id = string
    image_id = string
    env      = map(string)
    schedules = map(object({
      cron_expression = string
      path           = string
    }))
    identities = map(object({
      role = object({
        name = string
        arn  = string
      })
    }))
  })
}

variable "timeout" {
  description = "Function timeout in seconds"
  type        = number
  default     = 30
}

variable "memory" {
  description = "Memory allocation in MB"
  type        = number
  default     = 512
}

variable "ephemeral_storage" {
  description = "Ephemeral storage in MB"
  type        = number
  default     = 512
}

variable "architecture" {
  description = "Processor architecture"
  type        = string
  default     = "x86_64"
}

variable "function_url_auth_type" {
  description = "Authorization type for function URL"
  type        = string
  default     = "NONE"
}

variable "environment" {
  description = "Additional environment variables"
  type        = map(string)
  default     = {}
}
```

## Step 5: Define Lambda Outputs

```hcl
# aws-lambda/module/outputs.tf
output "function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.function.function_name
}

output "function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.function.arn
}

output "function_url" {
  description = "URL of the Lambda function"
  value       = aws_lambda_function_url.endpoint.function_url
}

output "invoke_arn" {
  description = "Invoke ARN of the Lambda function"
  value       = aws_lambda_function.function.invoke_arn
}
```

## Step 6: Update Your Platform Configuration

```yaml
# platform.yaml
name: my-storage-compute-platform
description: Platform with S3 storage and Lambda compute

libraries:
  my-aws: github.com/your-username/my-aws-plugins@v0.2.0

buckets:
  default:
    plugin: my-aws/aws-s3

services:
  default:
    plugin: my-aws/aws-lambda
    properties:
      memory: 512
      timeout: 30
```

## Step 7: Test Storage + Compute Integration

Create a test that shows S3 and Lambda working together:

```yaml
# nitric.yaml
targets:
  - file:platform.yaml
name: storage-compute-app
description: App with both storage and compute

services:
  api:
    properties:
      memory: 1024
      timeout: 60
    env:
      NODE_ENV: production
    container:
      docker:
        dockerfile: Dockerfile
        context: .
    dev:
      script: go run main.go

buckets:
  files:
    access:
      api:
        - read
        - write
```

## Understanding Lambda's Nitric Injection

When you define a service in your `nitric.yaml`:
```yaml
services:
  api:
    properties:
      memory: 1024
    env:
      NODE_ENV: production
    container:
      docker:
        dockerfile: Dockerfile
```

Nitric provides this to your Lambda plugin:
```hcl
var.nitric = {
  name = "api"                              # Service name from nitric.yaml
  stack_id = "myapp-dev-abc123"            # Unique deployment identifier  
  image_id = "myapp/api:latest"            # Docker image built by Nitric
  env = {                                   # Environment variables merged
    NODE_ENV = "production"                 # From your nitric.yaml
  }
  schedules = {}                            # Any cron schedules defined
  identities = {                            # IAM identities created by Nitric
    "aws:iam:role" = {
      role = {
        name = "myapp-dev-abc123-api-role"
        arn = "arn:aws:iam::123456789:role/myapp-dev-abc123-api-role"
      }
    }
  }
}
```

Plus your manifest properties:
```hcl
var.memory = 1024  # From properties in nitric.yaml (overrides default 512)
var.timeout = 30   # From manifest default
```

## How Cross-Plugin Permissions Work

The magic happens when you declare bucket access in `nitric.yaml`:

```yaml
buckets:
  files:
    access:
      api:        # This service name
        - read    # These permissions
        - write
```

The S3 plugin automatically receives:
```hcl
var.nitric.services = {
  "api" = {
    actions = ["read", "write"]
    identities = {
      "aws:iam:role" = {
        role = {
          name = "myapp-dev-abc123-api-role"  # Same role as Lambda!
          arn = "arn:aws:iam::123456789:role/myapp-dev-abc123-api-role"
        }
      }
    }
  }
}
```

This allows the S3 plugin to create IAM policies for the Lambda's role, granting it bucket access.

## Step 8: Publish Phase 2

```bash
git add .
git commit -m "Phase 2: Add Lambda plugin for compute"
git tag v0.2.0
git push origin main --tags
```

## Key Concepts from Phase 2

1. **Container Management**: Lambda plugin automatically handles ECR repositories and Docker image pushing
2. **Function URLs**: Each Lambda gets an HTTP endpoint automatically
3. **Scheduling**: Cron expressions are automatically converted to EventBridge schedules
4. **Cross-Service Access**: S3 plugin automatically creates IAM policies when services need bucket access

## Next Steps

In [Phase 3](Tutorial-Phase3-CloudFront.md), you'll add CloudFront CDN to create a complete web application platform. You'll see the full power of plugin composability as CloudFront automatically detects and configures both S3 and Lambda origins.