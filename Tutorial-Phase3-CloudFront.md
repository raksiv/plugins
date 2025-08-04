# Build Your Own Nitric Plugin Library - Phase 3: Add CloudFront CDN

This is phase 3 of a 3-part tutorial. In this phase, you'll add CloudFront to create a complete web application platform with CDN capabilities.

## Prerequisites

- Completed [Phase 1](Tutorial-Phase1-S3.md) and [Phase 2](Tutorial-Phase2-Lambda.md)
- Understanding of CDN concepts

## What You'll Learn

- Automatic origin detection (S3, Lambda, Load Balancer)
- Cross-resource permission setup
- WAF integration
- URL rewriting for clean paths

## Step 1: Add CloudFront Plugin Structure

```bash
# Create CloudFront plugin structure
mkdir -p aws-cloudfront/module/scripts
```

## Step 2: Create CloudFront Manifest

```yaml
# aws-cloudfront/manifest.yaml
name: "aws-cloudfront"
type: "resource"
description: "AWS CloudFront CDN with multiple origin support"
deployment:
  terraform: "module/"
properties:
  waf_enabled:
    type: "boolean"
    description: "Enable AWS WAF protection"
    default: false
  rate_limit_enabled:
    type: "boolean"
    description: "Enable rate limiting"
    default: false
  rate_limit_requests_per_5min:
    type: "number"
    description: "Rate limit requests per 5 minutes"
    default: 2000
  geo_restriction_type:
    type: "string"
    description: "Geographic restriction type"
    default: "none"
  geo_restriction_locations:
    type: "array"
    description: "List of country codes for geo restriction"
    default: []
  waf_managed_rules:
    type: "array"
    description: "List of AWS managed WAF rules"
    default: []
```

## Step 3: Create CloudFront Terraform

This is where the composability magic happens - CloudFront automatically detects origin types:

```hcl
# aws-cloudfront/module/main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# This shows the composability - CloudFront automatically detects different origin types
locals {
  s3_origin_id = "publicOrigin"
  default_origin = {
    for k, v in var.nitric.origins : k => v
    if v.path == "/"
  }
  s3_bucket_origins = {
    for k, v in var.nitric.origins : k => v
    if contains(keys(v.resources), "aws_s3_bucket")
  }
  lambda_origins = {
    for k, v in var.nitric.origins : k => v
    if contains(keys(v.resources), "aws_lambda_function")
  }
  non_vpc_origins = {
    for k, v in var.nitric.origins : k => v
    if !contains(keys(v.resources), "aws_lb")
  }
  vpc_origins = {
    for k, v in var.nitric.origins : k => v
    if contains(keys(v.resources), "aws_lb")
  }
}

resource "aws_cloudfront_vpc_origin" "vpc_origin" {
  for_each = local.vpc_origins

  vpc_origin_endpoint_config {
    name = each.key
    arn = each.value.resources["aws_lb"]
    http_port = each.value.resources["aws_lb:http_port"]
    https_port = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
 name = "com.amazonaws.global.cloudfront.origin-facing"
}

# Allow CloudFront to access load balancers
resource "aws_security_group_rule" "ingress" {
  for_each = local.vpc_origins
  security_group_id = each.value.resources["aws_lb:security_group"]
  from_port = each.value.resources["aws_lb:http_port"]
  to_port = each.value.resources["aws_lb:http_port"]
  protocol = "tcp"
  type = "ingress"

  prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
}

resource "aws_cloudfront_origin_access_control" "lambda_oac" {
  count = length(local.lambda_origins) > 0 ? 1 : 0

  name                              = "lambda-oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_origin_access_control" "s3_oac" {
  count = length(local.s3_bucket_origins) > 0 ? 1 : 0

  name                              = "s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Allow CloudFront to execute Lambda functions
resource "aws_lambda_permission" "allow_cloudfront_to_execute_lambda" {
  for_each = local.lambda_origins

  function_name = each.value.resources["aws_lambda_function"]
  principal = "cloudfront.amazonaws.com"
  action = "lambda:InvokeFunctionUrl"
  source_arn = aws_cloudfront_distribution.distribution.arn
}

# Allow CloudFront to access S3 buckets
resource "aws_s3_bucket_policy" "allow_bucket_access" {
  for_each = local.s3_bucket_origins

  bucket = replace(each.value.id, "arn:aws:s3:::", "")

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action = "s3:GetObject"
        Resource = "${each.value.id}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.distribution.arn
          }
        }
      }
    ]
  })
}

resource "aws_cloudfront_function" "api-url-rewrite-function" {
  name    = "api-url-rewrite-function"
  runtime = "cloudfront-js-1.0"
  comment = "Rewrite API URLs routed to Nitric services"
  publish = true
  code    = templatefile("${path.module}/scripts/url-rewrite.js", {
    base_paths = join(",", [for k, v in var.nitric.origins : v.path])
  })
}

resource "aws_wafv2_web_acl" "cloudfront_waf" {
  count = var.waf_enabled ? 1 : 0

  name   = "${var.nitric.name}-cloudfront-waf"
  scope  = "CLOUDFRONT"
  region = "us-east-1"

  default_action {
    allow {}
  }

  # Rate limiting rule
  dynamic "rule" {
    for_each = var.rate_limit_enabled ? [1] : []

    content {
      name     = "RateLimitRule"
      priority = 1

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit              = var.rate_limit_requests_per_5min
          aggregate_key_type = "IP"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "RateLimitRule"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = var.waf_managed_rules

    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = rule.value.override_action == "none" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = rule.value.override_action == "count" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudfront_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.nitric.name}-cloudfront-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudfront_distribution" "distribution" {
  enabled = true
  web_acl_id = var.waf_enabled ? aws_wafv2_web_acl.cloudfront_waf[0].arn : null

  # Non-VPC origins (S3 and Lambda)
  dynamic "origin" {
    for_each = local.non_vpc_origins

    content {
      domain_name = origin.value.domain_name
      origin_id = "${origin.key}"
      origin_access_control_id = contains(keys(origin.value.resources), "aws_lambda_function") ? aws_cloudfront_origin_access_control.lambda_oac[0].id : contains(keys(origin.value.resources), "aws_s3_bucket") ? aws_cloudfront_origin_access_control.s3_oac[0].id : null
      origin_path = origin.value.base_path

      dynamic "custom_origin_config" {
        for_each = !contains(keys(origin.value.resources), "aws_s3_bucket") ? [1] : []

        content {
          origin_read_timeout = 30
          origin_protocol_policy = "https-only"
          origin_ssl_protocols = ["TLSv1.2", "SSLv3"]
          http_port = 80
          https_port = 443
        }
      }
    }
  }

  # VPC origins (Load Balancers)
  dynamic "origin" {
    for_each = local.vpc_origins

    content {
      domain_name = origin.value.domain_name
      origin_id = "${origin.key}"
      vpc_origin_config {
        vpc_origin_id = aws_cloudfront_vpc_origin.vpc_origin[origin.key].id
      }
    }
  }

  # Cache behaviors for non-root paths
  dynamic "ordered_cache_behavior" {
    for_each = {
      for k, v in var.nitric.origins : k => v
      if v.path != "/"
    }

    content {
      path_pattern = "${ordered_cache_behavior.value.path}*"

      function_association {
        event_type = "viewer-request"
        function_arn = aws_cloudfront_function.api-url-rewrite-function.arn
      }

      allowed_methods = ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"]
      cached_methods = ["GET","HEAD","OPTIONS"]
      target_origin_id = "${ordered_cache_behavior.key}"

      forwarded_values {
        query_string = true
        cookies {
          forward = "all"
        }
      }

      viewer_protocol_policy = "https-only"
    }
  }

  # Default cache behavior
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "${keys(local.default_origin)[0]}"
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400

    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_type != "none" ? var.geo_restriction_locations : []
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
```

## Step 4: Add URL Rewrite Script

```javascript
// aws-cloudfront/module/scripts/url-rewrite.js
function handler(event) {
    var request = event.request;
    var uri = request.uri;
    
    // Base paths configured from Nitric origins
    var basePaths = "${base_paths}".split(',');
    
    // Rewrite logic for API paths
    for (var i = 0; i < basePaths.length; i++) {
        var basePath = basePaths[i];
        if (uri.startsWith(basePath) && basePath !== '/') {
            // Remove the base path for backend routing
            request.uri = uri.substring(basePath.length) || '/';
            break;
        }
    }
    
    return request;
}
```

## Step 5: Define CloudFront Variables

```hcl
# aws-cloudfront/module/variables.tf

variable "nitric" {
  description = "Nitric resource configuration"
  type = object({
    name = string
    origins = map(object({
      path = string
      domain_name = string
      base_path = string
      id = string
      resources = map(string)
    }))
  })
}

variable "waf_enabled" {
  description = "Enable AWS WAF protection"
  type        = bool
  default     = false
}

variable "rate_limit_enabled" {
  description = "Enable rate limiting"
  type        = bool
  default     = false
}

variable "rate_limit_requests_per_5min" {
  description = "Rate limit requests per 5 minutes"
  type        = number
  default     = 2000
}

variable "geo_restriction_type" {
  description = "Geographic restriction type"
  type        = string
  default     = "none"
}

variable "geo_restriction_locations" {
  description = "List of country codes for geo restriction"
  type        = list(string)
  default     = []
}

variable "waf_managed_rules" {
  description = "List of AWS managed WAF rules"
  type = list(object({
    name = string
    priority = number
    override_action = string
  }))
  default = []
}
```

## Step 6: Define CloudFront Outputs

```hcl
# aws-cloudfront/module/outputs.tf
output "distribution_id" {
  description = "ID of the CloudFront distribution"
  value       = aws_cloudfront_distribution.distribution.id
}

output "distribution_arn" {
  description = "ARN of the CloudFront distribution"
  value       = aws_cloudfront_distribution.distribution.arn
}

output "distribution_domain_name" {
  description = "Domain name of the CloudFront distribution"
  value       = aws_cloudfront_distribution.distribution.domain_name
}

output "distribution_hosted_zone_id" {
  description = "CloudFront Route 53 zone ID"
  value       = aws_cloudfront_distribution.distribution.hosted_zone_id
}
```

## Step 7: Update Platform for Complete Stack

```yaml
# platform.yaml
name: my-complete-aws-platform
description: Complete platform with S3, Lambda, and CloudFront

libraries:
  my-aws: github.com/your-username/my-aws-plugins@v0.3.0

buckets:
  default:
    plugin: my-aws/aws-s3

services:
  default:
    plugin: my-aws/aws-lambda
    properties:
      memory: 512
      timeout: 30

entrypoints:
  default:
    plugin: my-aws/aws-cloudfront
    properties:
      waf_enabled: false
```

## Step 8: Create a Complete Web Application

This example shows all three plugins working together:

```yaml
# nitric.yaml
targets:
  - file:platform.yaml
name: complete-web-app
description: Full web application with CDN

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
  static: {}

  uploads:
    access:
      api:
        - read
        - write

entrypoints:
  web:
    properties:
      waf_enabled: true
      rate_limit_enabled: true
    routes:
      /:
        name: static
      /api/*/:
        name: api
```

## Understanding CloudFront's Plugin Composability

### Automatic Origin Detection

The CloudFront plugin demonstrates true composability by automatically detecting origin types:

```hcl
# Automatically finds S3 buckets
s3_bucket_origins = {
  for k, v in var.nitric.origins : k => v
  if contains(keys(v.resources), "aws_s3_bucket")
}

# Automatically finds Lambda functions
lambda_origins = {
  for k, v in var.nitric.origins : k => v
  if contains(keys(v.resources), "aws_lambda_function")
}

# Automatically finds Load Balancers
vpc_origins = {
  for k, v in var.nitric.origins : k => v
  if contains(keys(v.resources), "aws_lb")
}
```

### Understanding CloudFront's Nitric Injection

When you define an entrypoint:
```yaml
entrypoints:
  web:
    properties:
      waf_enabled: true
    routes:
      /:
        name: static  # S3 bucket
      /api/*/:
        name: api
```

Nitric provides rich origin information:
```hcl
var.nitric = {
  name = "web"
  origins = {
    "api-root" = {
      path = "/"
      domain_name = "abc123.lambda-url.us-east-1.on.aws"
      base_path = ""
      id = "arn:aws:lambda:us-east-1:123456789:function:myapp-dev-abc123-api"
      resources = {
        "aws_lambda_function" = "myapp-dev-abc123-api"
      }
    }
    "static-static" = {
      path = "/static/"
      domain_name = "myapp-dev-abc123-static.s3.amazonaws.com"
      base_path = ""
      id = "arn:aws:s3:::myapp-dev-abc123-static"
      resources = {
        "aws_s3_bucket" = "myapp-dev-abc123-static"
      }
    }
  }
}
```

### Automatic Permission Setup

CloudFront automatically sets up the right permissions for each origin type:

1. **For S3 Origins**: Creates bucket policies allowing CloudFront access
2. **For Lambda Origins**: Creates Lambda permissions for function URL execution
3. **For Load Balancer Origins**: Configures security groups for CloudFront access

## Step 9: Publish Complete Platform

```bash
git add .
git commit -m "Phase 3: Add CloudFront plugin for complete web platform"
git tag v0.3.0
git push origin main --tags
```

## Complete Example: Static Site with API

Here's how the three plugins work together for a typical web application:

```yaml
# nitric.yaml
targets:
  - file:platform.yaml
name: my-website
description: Static site with API backend

services:
  # API backend
  api:
    properties:
      memory: 1024
    env:
      API_VERSION: v1
    container:
      docker:
        dockerfile: api/Dockerfile
        context: api

buckets:
  # Static website assets
  website: {}
  
  # User uploads
  uploads:
    access:
      api:
        - read
        - write
        - delete

entrypoints:
  # Main CDN
  cdn:
    properties:
      waf_enabled: true
      rate_limit_enabled: true
      waf_managed_rules:
        - name: "AWSManagedRulesCommonRuleSet"
          priority: 2
          override_action: "none"
    routes:
      # Static assets from S3
      /:
        name: website
      # API calls to Lambda
      /api/*/:
        name: api
```

This creates:
1. **S3 Buckets**: `website` for static files, `uploads` for user content
2. **Lambda Function**: `api` with access to the uploads bucket
3. **CloudFront Distribution**: 
   - Serves static files from S3 at `/`
   - Routes API calls to Lambda at `/api/*`
   - WAF protection enabled
   - Automatic permission setup for all resources

## Key Concepts from Phase 3

1. **Automatic Origin Detection**: CloudFront automatically detects S3, Lambda, and Load Balancer origins
2. **Cross-Resource Integration**: CloudFront automatically sets up permissions for S3 and Lambda access
3. **Flexible Routing**: Different paths can route to different services
4. **Security Integration**: WAF can be easily enabled with managed rules

## Summary: The Power of Composability

Through these three phases, you've built a plugin system where:

1. **Each Plugin Has One Job**: S3 manages buckets, Lambda manages functions, CloudFront manages CDN
2. **Nitric Handles Integration**: Through dependency injection, plugins receive exactly what they need
3. **Permissions Are Automatic**: Cross-resource access is configured based on your `nitric.yaml`
4. **Plugins Discover Resources**: CloudFront automatically detects and configures different origin types
5. **Configuration Is Flexible**: Two-file system allows sharing platforms while customizing projects

## Next Steps

Your plugin library now supports the complete web application stack. You can extend it by:

1. **Add More AWS Services**: 
   - DynamoDB for databases
   - SQS for message queues
   - API Gateway for REST APIs

2. **Add Other Cloud Providers**: 
   - Azure equivalents
   - GCP equivalents

3. **Add Specialized Features**:
   - Custom domains
   - Certificate management
   - Monitoring and alerting

The composable design means each new plugin can automatically integrate with existing ones through Nitric's dependency injection system.