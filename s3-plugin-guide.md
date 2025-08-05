# Building an S3 Bucket Plugin

This guide shows how to create a modular Terraform plugin that builds S3 buckets compatible with any application or service, including CloudFront CDN.

## Key Features

### Multi-Consumer Architecture

The plugin creates buckets that can serve any type of application or service: Lambda functions, Kubernetes pods, EC2 instances, containers, and CDNs all need different access patterns. We solve this by:

- **Standard IAM policies**: Creates policies that attach to Lambda execution roles, EC2 instance profiles, ECS task roles, or any custom IAM role
- **Granular permissions**: Each application gets only the S3 actions it needs (read, write, delete) rather than blanket access

### Naming Strategy

Bucket names must be globally unique in AWS. We use `{stack-id}-{bucket-name}` to prevent conflicts while keeping names predictable for any application that needs to access them.

### Resource Discovery

Other systems (like CloudFront) can automatically find S3 buckets by looking for exported resources with the `aws_s3_bucket` key. This eliminates manual configuration between services.

### Static Content Support

The plugin can automatically upload files from a local directory to the bucket during deployment. This enables use cases like static websites or pre-loading application assets, with automatic MIME type detection for proper browser handling.

## Implementation

### 1. Create Directory Structure

```
s3-bucket-module/
├── main.tf       # Creates bucket and permissions
├── variables.tf  # Input parameters
├── outputs.tf    # Exports for other systems
└── providers.tf  # Required tools
```

### 2. Terraform Providers (`providers.tf`)

Specifies the corefunc provider for string manipulation functions.
We need to convert bucket names to kebab-case format for AWS naming requirements.

```hcl
terraform {
  required_providers {
    corefunc = {
      source  = "northwood-labs/corefunc"
      version = "~> 1.4"
    }
  }
}
```

### 3. Input Variables (`variables.tf`)

Defines what information callers will pass to the module.
The module needs bucket name, consumer permissions, and content paths to create the right resources.

```hcl
variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for bucket naming to ensure uniqueness (e.g., project name, environment)"
}

variable "static_files_path" {
  type        = string
  default     = ""
  description = "Local path to static files to upload to bucket"
}

variable "services" {
  type = map(object({
    actions = list(string)
    iam_role = any
  }))
  default     = {}
  description = "Services that need access to the bucket"
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

### 4. Main Infrastructure (`main.tf`)

Creates the S3 bucket, uploads content, and sets up IAM permissions for services.
This is where the actual AWS resources get built with proper security boundaries.

```hcl
locals {
  normalized_bucket_name = provider::corefunc::str_kebab(var.bucket_name)
}

resource "aws_s3_bucket" "bucket" {
  bucket = "${var.name_prefix}-${local.normalized_bucket_name}"
  tags   = var.tags
}

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
  relative_content_path = "${path.root}/../../../${var.static_files_path}"
  content_files = var.static_files_path != "" ? fileset(local.relative_content_path, "**/*") : []
}

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

resource "aws_iam_role_policy" "access_policy" {
  for_each = var.services
  name     = "${local.normalized_bucket_name}-${provider::corefunc::str_kebab(each.key)}"
  role     = each.value.iam_role.name

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

### 5. Outputs for Discovery (`outputs.tf`)

Exports bucket information so CloudFront and other systems can discover and use it.
Without these exports, other plugins wouldn't know this S3 bucket exists or how to access it.

```hcl
output "bucket_arn" {
  value = aws_s3_bucket.bucket.arn
}

output "bucket_name" {
  value = aws_s3_bucket.bucket.bucket
}

output "bucket_domain_name" {
  value = aws_s3_bucket.bucket.bucket_regional_domain_name
}

output "discovery_tags" {
  value = {
    "aws_s3_bucket" = aws_s3_bucket.bucket.arn
  }
  description = "Tags for automatic discovery by other systems"
}
```

## Key Design Elements

**Bucket Creation**: Uses name prefix + normalized bucket name for global uniqueness
**Permission Management**: Creates IAM policies for each service with only requested permissions
**Static Content**: Automatically uploads files with proper MIME types if static_files_path provided
**Discovery Integration**: Exports `aws_s3_bucket` identifier for automatic discovery by other modules
**Security**: Follows least-privilege principle - services get only what they request

## How to Use This Module

Here's a complete example showing how to create an S3 bucket for a photo processing application:

```hcl
# First create your application's IAM role
resource "aws_iam_role" "photo_processor" {
  name = "photo-processor-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"  # or ec2.amazonaws.com, etc.
      }
    }]
  })
}

# Then use the S3 bucket module
module "photos_bucket" {
  source = "./aws/s3"

  bucket_name        = "photos"
  name_prefix        = "mycompany-prod"
  static_files_path  = ""

  services = {
    "photo-processor" = {
      actions  = ["read", "write"]
      iam_role = aws_iam_role.photo_processor
    }
  }

  tags = {
    Environment = "production"
    Project     = "photo-app"
  }
}
```

The module creates the S3 bucket, uploads any static files, and generates IAM policies for each service. For example, the photo-processor gets this policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": ["s3:GetObject", "s3:ListBucket", "s3:PutObject"],
      "Effect": "Allow",
      "Resource": [
        "arn:aws:s3:::mycompany-prod-photos",
        "arn:aws:s3:::mycompany-prod-photos/*"
      ]
    }
  ]
}
```

### Application Runtime Access

After the module creates the buckets, applications access them using standard AWS patterns:

1. **Direct AWS SDK calls** - Use any AWS SDK with the predictable bucket naming pattern (`{name-prefix}-{bucket-name}`)
2. **IAM role credentials** - Applications get permissions through the IAM roles you configured in the module
3. **Framework-specific integrations** - Build adapters for specific frameworks that translate to AWS calls

Example application code:

```go
bucketName := "mycompany-prod-photos"  // {name-prefix}-{bucket-name}
s3Client.GetObject(ctx, &s3.GetObjectInput{
    Bucket: aws.String(bucketName),
    Key:    aws.String("my-photo.jpg"),
})
```

## CloudFront Integration

CloudFront automatically:

1. Discovers buckets by scanning for `aws_s3_bucket` in resource exports
2. Creates Origin Access Control for secure access
3. Applies bucket policies allowing only the specific CloudFront distribution

This creates a dual-access system: services use IAM roles while CloudFront uses OAC - both can access the same bucket securely.

## Making It Compatible with Nitric

### Why This Approach is Valuable

Rather than building separate S3 modules for each framework, this pattern provides significant benefits:

**For Module Maintainers:**

- **Single source of truth**: All S3 logic lives in one place - bug fixes and features benefit everyone
- **Easier testing**: Test the core logic once, rather than maintaining identical tests across multiple modules
- **Reduced duplication**: No copy-paste of bucket creation, IAM policies, or encryption logic

**For Organizations:**

- **Consistency**: Same S3 configuration whether you use Terraform directly, Nitric, CDK, or other tools
- **Knowledge transfer**: Developers who learn the generic module can use it anywhere
- **Migration flexibility**: Easy to move between frameworks without rewriting infrastructure

### Implementation

If you want to use this generic Terraform module within the Nitric framework, you need to add a plugin wrapper that adapts the module's interface to Nitric's expectations.

### Plugin Structure

Create a Nitric plugin directory that wraps your module:

```
aws/s3/
├── manifest.yaml     # Nitric plugin metadata
├── icon.svg          # Plugin icon
└── module/           # Your existing Terraform module
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── providers.tf
```

### Plugin Manifest (`manifest.yaml`)

```yaml
name: aws-s3-bucket
type: storage
icon: ./icon.svg
required_identities:
  - aws:iam:role
deployment:
  terraform: ./module
runtime:
  go_module: github.com/nitrictech/plugins/aws/s3
inputs:
  tags:
    type: map(string)
outputs: {}
```

### Wrapper Module (`module/main.tf`)

Create a wrapper that calls your generic module without modifying it:

```hcl
# Transform Nitric service format to generic module format
locals {
  services = {
    for name, service in var.nitric.services : name => {
      actions  = service.actions
      iam_role = service.identities["aws:iam:role"].role
    }
  }
}

# Call the generic S3 module
module "s3_bucket" {
  source = "../../../s3-bucket-module"  # Path to your generic module

  bucket_name       = var.nitric.name
  name_prefix       = var.nitric.stack_id
  static_files_path = var.nitric.content_path
  services         = local.services
  tags              = var.tags
}
```

### Wrapper Variables (`module/variables.tf`)

The wrapper accepts Nitric's input format:

```hcl
variable "nitric" {
  type = object({
    name         = string
    stack_id     = string
    content_path = string
    services = map(object({
      actions = list(string)
      identities = map(object({
        id   = string
        role = any
      }))
    }))
  })
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

### Wrapper Outputs (`module/outputs.tf`)

Transform the generic module's outputs to Nitric's expected format:

```hcl
output "nitric" {
  value = {
    id = module.s3_bucket.bucket_arn
    domain_name = module.s3_bucket.bucket_domain_name
    exports = {
      env = {}
      resources = module.s3_bucket.discovery_tags
    }
  }
}
```

Your module is now ready to be orchestrated by any platform.
