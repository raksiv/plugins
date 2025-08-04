# Test Project - Nitric AWS Plugin Library

This is a complete test project demonstrating your custom AWS plugin library with S3, Lambda, and CloudFront using native AWS SDKs.

## 🏗️ Architecture

- **Static Website**: HTML/CSS/JS served from S3 via CloudFront
- **API Service**: Go Lambda function using AWS SDK v2 for S3 operations
- **Storage**: S3 bucket for user uploads with automatic permissions
- **CDN**: CloudFront distribution with WAF protection and rate limiting

## 🚀 How to Deploy

1. **Prerequisites**:
   ```bash
   # Install Nitric CLI
   curl -L https://nitric.io/install | bash
   
   # Install Go dependencies
   go mod tidy
   ```

2. **Deploy to AWS**:
   ```bash
   # Deploy the complete stack
   nitric up
   
   # This will:
   # - Download your plugins from GitHub
   # - Create S3 buckets (website, uploads)
   # - Build and deploy Lambda function
   # - Create CloudFront distribution with WAF
   # - Set up all cross-resource permissions automatically
   ```

3. **Upload Static Files**:
   ```bash
   # Upload static website files to S3
   nitric build
   ```

## 🔗 What Gets Created

### S3 Buckets
- `my-test-website-dev-xxx-website`: Static website files
- `my-test-website-dev-xxx-uploads`: User file uploads

### Lambda Function  
- `my-test-website-dev-xxx-api`: Go API service using AWS SDK v2

### CloudFront Distribution
- Routes `/` to website S3 bucket
- Routes `/api/*` to Lambda function
- WAF protection with rate limiting (1000 req/5min)
- AWS managed security rules

## 🧪 API Endpoints

- `GET /api/health` - Health check
- `GET /api/files` - List uploaded files
- `POST /api/upload` - Upload file (JSON with base64 content)
- `GET /api/files/:filename` - Download specific file
- `DELETE /api/files/:filename` - Delete file

## 🎯 Testing

1. Open the CloudFront domain URL in your browser
2. Use the web interface to test API endpoints
3. Upload files and verify they're stored in S3
4. Check that all routes work through the CDN

## 🔧 Local Development

```bash
# Install Go dependencies
go mod tidy

# Run API locally (requires Nitric local development setup)
nitric run

# The static files will be served from the website bucket
# API calls will go to the local Lambda simulator
```

## 📦 Plugin Components Used

- **aws-s3**: Bucket creation with content upload and cross-service access
- **aws-lambda**: Container-based Lambda with ECR, IAM roles, and function URLs
- **aws-cloudfront**: CDN with automatic origin detection, WAF, and URL rewriting

## 🔧 Key Features

- **Native AWS SDK**: Uses `github.com/aws/aws-sdk-go-v2` for direct S3 operations
- **Standard HTTP Server**: Gorilla Mux router with proper CORS handling
- **Environment-Based Config**: Bucket names automatically configured by Nitric
- **IAM Integration**: Works with IAM roles created by your Nitric plugins
- **Container Deployment**: Multi-stage Docker build for optimized Lambda images

This demonstrates the full power of composable Nitric plugins working with native cloud SDKs!