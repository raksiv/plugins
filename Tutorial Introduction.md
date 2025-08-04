# Build Your Own Nitric Plugin Library

This is a 3-phase tutorial that teaches you how to build composable AWS infrastructure plugins for Nitric. You'll learn by building incrementally, starting with simple storage and ending with a complete web application platform.

## What You'll Build

### [Phase 1: S3 Storage](Tutorial-Phase1-S3.md)

Start with the fundamentals by building an S3 bucket plugin. You'll learn:

- Plugin structure and manifests
- Nitric's dependency injection system
- Automatic IAM policy generation
- How Nitric provides context to plugins

### [Phase 2: Add Lambda Functions](Tutorial-Phase2-Lambda.md)

Add compute capabilities with a Lambda plugin. You'll learn:

- Container-based deployments with ECR
- EventBridge scheduling integration
- Cross-plugin permissions (S3 ↔ Lambda)
- How plugins work together

### [Phase 3: Add CloudFront CDN](Tutorial-Phase3-CloudFront.md)

Complete your platform with CloudFront. You'll learn:

- Automatic origin detection
- Complex resource integration
- WAF and security features
- The full power of plugin composability

## Prerequisites

- GitHub account
- Basic Terraform knowledge
- AWS account (for testing)
- Docker (for Phase 2+)

Ready to start? Head to [Phase 1: S3 Storage](Tutorial-Phase1-S3.md)!
