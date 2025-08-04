# Build Your Own Nitric Plugin Library - Phase 1: S3 Storage

This is phase 1 of a 3-part tutorial on building composable AWS plugins for Nitric. In this phase, you'll learn the fundamentals by creating an S3 bucket plugin.

## What You'll Learn

- Plugin structure and manifest files
- Nitric's dependency injection system
- How plugins receive configuration and context
- Automatic IAM policy generation

## Prerequisites

- GitHub account
- Basic Terraform knowledge
- AWS account (for testing)

## Step 1: Create Your Plugin Repository

```bash
# Create and navigate to your project
mkdir my-aws-plugins
cd my-aws-plugins

# Initialize git
git init

# Create the basic structure
mkdir -p aws-s3/module
echo "# My AWS Plugins for Nitric" > README.md
```

## Step 2: Create the S3 Plugin Manifest

The manifest tells Nitric about your plugin:

```yaml
# aws-s3/manifest.yaml
name: "aws-s3"
type: "resource"
description: "AWS S3 bucket for object storage"
deployment:
  terraform: "module/"
properties:
  # You can add custom properties here that will be configurable in platform.yaml
  # For example: custom_setting, enable_feature, etc.
```

## Step 3: Create the Terraform Implementation

```hcl
# aws-s3/module/main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Local variables for processing Nitric injected data
locals {
  normalized_nitric_name = provider::corefunc::str_kebab(var.nitric.name)
  relative_content_path = "${path.root}/../../../${var.nitric.content_path}"
  content_files = var.nitric.content_path != "" ? fileset(local.relative_content_path, "**/*") : []
}

# Main S3 bucket - name is generated from Nitric stack and resource name
resource "aws_s3_bucket" "bucket" {
  bucket = "${var.nitric.stack_id}-${local.normalized_nitric_name}"
  tags   = var.tags
}

# Upload files if content path is provided by Nitric
resource "aws_s3_object" "files" {
  for_each = toset(local.content_files)

  bucket = aws_s3_bucket.bucket.bucket
  key    = each.value
  source = "${local.relative_content_path}/${each.value}"

  etag = filemd5("${local.relative_content_path}/${each.value}")

  content_type = lookup({
    "html" = "text/html"
    "css"  = "text/css"
    "js"   = "application/javascript"
    "json" = "application/json"
    "png"  = "image/png"
    "jpg"  = "image/jpeg"
    "jpeg" = "image/jpeg"
    "gif"  = "image/gif"
    "svg"  = "image/svg+xml"
    "pdf"  = "application/pdf"
    "txt"  = "text/plain"
  }, reverse(split(".", each.value))[0], "application/octet-stream")
}

# Automatically create IAM policies for services that need bucket access
locals {
  read_actions = [
    "s3:GetObject",
    "s3:ListBucket",
  ]
  write_actions = [
    "s3:PutObject",
  ]
  delete_actions = [
    "s3:DeleteObject",
  ]
}

resource "aws_iam_role_policy" "access_policy" {
  for_each = var.nitric.services
  name     = "${local.normalized_nitric_name}-${provider::corefunc::str_kebab(each.key)}"
  role     = each.value.identities["aws:iam:role"].role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = distinct(concat(
          contains(each.value.actions, "read") ? local.read_actions : [],
          contains(each.value.actions, "write") ? local.write_actions : [],
          contains(each.value.actions, "delete") ? local.delete_actions : []
          )
        )
        Effect   = "Allow"
        Resource = [
          aws_s3_bucket.bucket.arn,
          "${aws_s3_bucket.bucket.arn}/*"
        ]
      },
    ]
  })
}
```

## Step 4: Define Variables

```hcl
# aws-s3/module/variables.tf

# Standard Nitric variable - automatically injected by the framework
variable "nitric" {
  description = "Nitric resource configuration"
  type = object({
    name         = string
    stack_id     = string
    content_path = string
    services = map(object({
      actions = list(string)
      identities = map(object({
        role = object({
          name = string
          arn  = string
        })
      }))
    }))
  })
}

variable "tags" {
  description = "Tags to apply to the bucket"
  type        = map(string)
  default     = {}
}
```

## Step 5: Export Outputs

```hcl
# aws-s3/module/outputs.tf
output "bucket_id" {
  description = "ID of the S3 bucket"
  value       = aws_s3_bucket.bucket.id
}

output "bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.bucket.arn
}

output "bucket_domain_name" {
  description = "Domain name of the S3 bucket"
  value       = aws_s3_bucket.bucket.bucket_domain_name
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the S3 bucket"
  value       = aws_s3_bucket.bucket.bucket_regional_domain_name
}
```

## Step 6: Create Your Platform Configuration

Create the platform file that defines which plugins to use:

```yaml
# platform.yaml
name: my-s3-platform
description: Simple S3-only platform

libraries:
  my-aws: github.com/your-username/my-aws-plugins@v0.1.0

buckets:
  default:
    plugin: my-aws/aws-s3
```

## Step 7: Test Your S3-Only Platform

Create a test project:

```yaml
# nitric.yaml
targets:
  - file:platform.yaml
name: s3-test-app
description: Testing S3 bucket functionality

buckets:
  # Static website files
  website:
    # Uses default plugin from platform.yaml

  # User uploads
  uploads:
    # Uses default plugin from platform.yaml
```

## Step 8: Publish Your Plugin

```bash
git add .
git commit -m "Phase 1: Add S3 bucket plugin"
git tag v0.1.0
git push origin v0.1.0
```

## Understanding What Nitric Injects

When you define a bucket in your `nitric.yaml`:

```yaml
buckets:
  uploads:
    access:
      api:
        - read
        - write
```

Nitric automatically provides this data to your S3 plugin's terraform, this is how the S3 plugin knows:

- What to name the bucket
- Which services need access
- What permissions to grant
- Which IAM roles to attach policies to

```hcl
var.nitric = {
  name = "uploads"                    # The bucket name from nitric.yaml
  stack_id = "myapp-dev-abc123"       # Unique deployment identifier
  content_path = ""                   # Path to static files (if any)
  services = {                        # Services with access to this bucket
    "api" = {
      actions = ["read", "write"]     # Permissions from nitric.yaml
      identities = {
        "aws:iam:role" = {
          role = {
            name = "myapp-dev-abc123-api-role"
            arn = "arn:aws:iam::123456789:role/myapp-dev-abc123-api-role"
          }
        }
      }
    }
  }
}
```

## Key Concepts from Phase 1

1. **Nitric Dependency Injection**: The `var.nitric` variable contains all the context your plugin needs
2. **Automatic Naming**: Bucket names are generated using `${var.nitric.stack_id}-${var.nitric.name}`
3. **Content Upload**: If a content path is provided, files are automatically uploaded
4. **Service Integration**: The plugin automatically creates IAM policies for services that need access

## Next Steps

In [Phase 2](Tutorial-Phase2-Lambda.md), you'll add Lambda support to create a platform that supports both storage and compute. You'll learn how plugins work together and how Nitric manages cross-resource permissions.
