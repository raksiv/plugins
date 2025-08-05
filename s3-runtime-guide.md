## Extending the Plugin

The base plugin provides essential S3 functionality, but you can extend it with additional features. Here's how to add bucket encryption as an example.

### Adding Bucket Encryption

**Why extend**: S3 buckets should be encrypted at rest to protect sensitive data. This is a common security requirement not included in the base plugin.

**Implementation**: Add this resource to your `main.tf`:

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "bucket_encryption" {
  bucket = aws_s3_bucket.bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}
```

**Extension principles**:

- **Reference existing resources**: Uses `aws_s3_bucket.bucket.id` from the base module
- **Add optional features**: Encryption doesn't break existing functionality
- **Follow AWS best practices**: AES256 with bucket_key_enabled for cost optimization
- **Maintain transparency**: Applications don't need changes - encryption happens automatically

### Other Extension Ideas

- **Versioning**: Enable object versioning for data protection
- **Lifecycle policies**: Automatically move old files to cheaper storage tiers
- **Cross-region replication**: Replicate buckets across regions for disaster recovery
- **Access logging**: Track who accesses your bucket and when

Each extension follows the same pattern: add new Terraform resources that reference the base bucket while maintaining compatibility with existing applications and CloudFront integration.

# Accessing S3 Buckets from Applications

This guide shows different ways applications can access the S3 buckets created by the Terraform plugin. The buckets are designed to work with any type of application or service.

## Universal Access Methods

### Direct AWS SDK Access

Any application can access the buckets using standard AWS SDKs:

```go
import "github.com/aws/aws-sdk-go-v2/service/s3"

// Use the same naming pattern as Terraform
bucketName := fmt.Sprintf("%s-%s", stackId, bucketName)

// Standard AWS S3 operations
s3Client.GetObject(ctx, &s3.GetObjectInput{
    Bucket: aws.String(bucketName),
    Key:    aws.String("my-file.jpg"),
})
```

**Works with**: Lambda functions, Kubernetes pods, EC2 instances, containers, serverless functions, traditional applications

### Bucket Name Consistency

All applications must use the same naming pattern as Terraform: `{stack-id}-{bucket-name}`. This ensures any service can predictably find the buckets.

### Credential Requirements

Applications need AWS credentials with the IAM permissions that were created by the Terraform plugin. These credentials can come from:

- IAM roles (Lambda, EC2, ECS)
- Environment variables
- AWS credential files
- Instance metadata

## Nitric Runtime Integration (Optional)

If you're building specifically for Nitric applications, you can also create a runtime plugin that implements Nitric's storage interface.

### Finding the Storage Interface

For Nitric integration, you need:

1. **Check the manifest**: `type: storage` indicates this creates a storage resource
2. **Runtime interface**: `github.com/nitrictech/nitric/runtime/storage` defines the `Storage` interface
3. **gRPC operations**: `github.com/nitrictech/nitric/proto/storage/v2` defines the storage operations

### Protocol Implementation

A Nitric runtime plugin implements:

- **`storage.Storage`** - returned by `Plugin()` to register with Nitric's runtime
- **`storagepb.UnimplementedStorageServer`** - handles gRPC storage operations

### Error Handling

Distinguish between permission errors (configuration issues) and operational errors for better debugging.

## Implementation

### 1. Create the Package Structure

```
aws/s3/s3.go
```

### 2. Package Dependencies

Add to your `go.mod`:

```go
require (
    github.com/aws/aws-sdk-go v1.55.7
    github.com/aws/aws-sdk-go-v2/config v1.29.17
    github.com/aws/aws-sdk-go-v2/service/s3 v1.82.0
    github.com/aws/smithy-go v1.22.4
    github.com/iancoleman/strcase v0.3.0
    github.com/nitrictech/nitric/proto v0.0.0-20250701100118-e6d54bdc8d8a
    github.com/nitrictech/nitric/runtime v0.0.0-20250701100118-e6d54bdc8d8a
    google.golang.org/grpc v1.72.0
)
```

### 3. Core Structure and Naming (`s3.go`)

Implements the storage interface with consistent bucket naming:

```go
package awss3

import (
    "context"
    "fmt"
    "os"

    "github.com/aws/aws-sdk-go-v2/config"
    "github.com/aws/aws-sdk-go-v2/service/s3"
    "github.com/iancoleman/strcase"
    storagepb "github.com/nitrictech/nitric/proto/storage/v2"
    "github.com/nitrictech/nitric/runtime/storage"
)

type s3Storage struct {
    storagepb.UnimplementedStorageServer
    nitricStackId string
    s3Client      *s3.Client
    preSignClient *s3.PresignClient
}

// Critical: Must match Terraform naming exactly
func (s *s3Storage) getS3BucketName(bucket string) string {
    normalizedBucketName := strcase.ToKebab(bucket)
    return fmt.Sprintf("%s-%s", s.nitricStackId, normalizedBucketName)
}

func Plugin() (storage.Storage, error) {
    nitricStackId := os.Getenv("NITRIC_STACK_ID")
    if nitricStackId == "" {
        return nil, fmt.Errorf("NITRIC_STACK_ID is not set")
    }

    cfg, err := config.LoadDefaultConfig(context.TODO())
    if err != nil {
        return nil, err
    }

    s3Client := s3.NewFromConfig(cfg)
    preSignClient := s3.NewPresignClient(s3Client)

    return &s3Storage{
        s3Client:      s3Client,
        preSignClient: preSignClient,
        nitricStackId: nitricStackId,
    }, nil
}
```

### 4. Storage Operations

Implement the six core operations with proper error handling:

```go
import (
    "bytes"
    "errors"
    "io"
    "mime"
    "net/http"
    "path/filepath"
    "strings"

    "github.com/aws/aws-sdk-go/aws"
    "github.com/aws/smithy-go"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
)

// Helper for detecting permission errors
func isS3AccessDeniedErr(err error) bool {
    var opErr *smithy.OperationError
    if errors.As(err, &opErr) {
        return opErr.Service() == "S3" && strings.Contains(opErr.Unwrap().Error(), "AccessDenied")
    }
    return false
}

// Read files from S3
func (s *s3Storage) Read(ctx context.Context, req *storagepb.StorageReadRequest) (*storagepb.StorageReadResponse, error) {
    bucketName := s.getS3BucketName(req.BucketName)

    resp, err := s.s3Client.GetObject(ctx, &s3.GetObjectInput{
        Bucket: aws.String(bucketName),
        Key:    aws.String(req.Key),
    })
    if err != nil {
        if isS3AccessDeniedErr(err) {
            return nil, status.Errorf(codes.PermissionDenied, "unable to read file, this may be due to a missing permissions request in your code.")
        }
        return nil, status.Errorf(codes.Unknown, "error reading file: %v", err)
    }

    defer resp.Body.Close()
    bodyBytes, err := io.ReadAll(resp.Body)
    if err != nil {
        return nil, err
    }

    return &storagepb.StorageReadResponse{
        Body: bodyBytes,
    }, nil
}

// Content type detection for uploads
func detectContentType(filename string, content []byte) string {
    contentType := mime.TypeByExtension(filepath.Ext(filename))
    if contentType != "" {
        return contentType
    }
    return http.DetectContentType(content)
}

// Write files to S3
func (s *s3Storage) Write(ctx context.Context, req *storagepb.StorageWriteRequest) (*storagepb.StorageWriteResponse, error) {
    bucketName := s.getS3BucketName(req.BucketName)
    contentType := detectContentType(req.Key, req.Body)

    if _, err := s.s3Client.PutObject(ctx, &s3.PutObjectInput{
        Bucket:      aws.String(bucketName),
        Body:        bytes.NewReader(req.Body),
        ContentType: &contentType,
        Key:         aws.String(req.Key),
    }); err != nil {
        if isS3AccessDeniedErr(err) {
            return nil, status.Errorf(codes.PermissionDenied, "unable to write file, this may be due to a missing permissions request in your code.")
        }
        return nil, status.Errorf(codes.Unknown, "error writing file: %v", err)
    }

    return &storagepb.StorageWriteResponse{}, nil
}

// Delete files from S3
func (s *s3Storage) Delete(ctx context.Context, req *storagepb.StorageDeleteRequest) (*storagepb.StorageDeleteResponse, error) {
    bucketName := s.getS3BucketName(req.BucketName)

    if _, err := s.s3Client.DeleteObject(ctx, &s3.DeleteObjectInput{
        Bucket: aws.String(bucketName),
        Key:    aws.String(req.Key),
    }); err != nil {
        if isS3AccessDeniedErr(err) {
            return nil, status.Errorf(codes.PermissionDenied, "unable to delete file, this may be due to a missing permissions request in your code.")
        }
        return nil, status.Errorf(codes.Unknown, "error deleting file: %v", err)
    }

    return &storagepb.StorageDeleteResponse{}, nil
}

// List files in bucket
func (s *s3Storage) ListBlobs(ctx context.Context, req *storagepb.StorageListBlobsRequest) (*storagepb.StorageListBlobsResponse, error) {
    bucketName := s.getS3BucketName(req.BucketName)

    objects, err := s.s3Client.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
        Bucket: aws.String(bucketName),
        Prefix: aws.String(req.Prefix),
    })
    if err != nil {
        if isS3AccessDeniedErr(err) {
            return nil, status.Errorf(codes.PermissionDenied, "unable to list files, this may be due to a missing permissions request in your code.")
        }
        return nil, status.Errorf(codes.Unknown, "error listing files: %v", err)
    }

    files := make([]*storagepb.Blob, 0, len(objects.Contents))
    for _, o := range objects.Contents {
        files = append(files, &storagepb.Blob{
            Key: *o.Key,
        })
    }

    return &storagepb.StorageListBlobsResponse{
        Blobs: files,
    }, nil
}

// Check if file exists
func (s *s3Storage) Exists(ctx context.Context, req *storagepb.StorageExistsRequest) (*storagepb.StorageExistsResponse, error) {
    bucketName := s.getS3BucketName(req.BucketName)

    _, err := s.s3Client.HeadObject(ctx, &s3.HeadObjectInput{
        Bucket: aws.String(bucketName),
        Key:    aws.String(req.Key),
    })
    if err != nil {
        if isS3AccessDeniedErr(err) {
            return nil, status.Errorf(codes.PermissionDenied, "unable to check if file exists, this may be due to a missing permissions request in your code.")
        }
        return &storagepb.StorageExistsResponse{
            Exists: false,
        }, nil
    }

    return &storagepb.StorageExistsResponse{
        Exists: true,
    }, nil
}

// Generate temporary access URLs
func (s *s3Storage) PreSignUrl(ctx context.Context, req *storagepb.StoragePreSignUrlRequest) (*storagepb.StoragePreSignUrlResponse, error) {
    bucketName := s.getS3BucketName(req.BucketName)

    switch req.Operation {
    case storagepb.StoragePreSignUrlRequest_READ:
        response, err := s.preSignClient.PresignGetObject(ctx, &s3.GetObjectInput{
            Bucket: aws.String(bucketName),
            Key:    aws.String(req.Key),
        }, s3.WithPresignExpires(req.Expiry.AsDuration()))
        if err != nil {
            return nil, status.Errorf(codes.Internal, "failed to generate signed READ URL: %v", err)
        }
        return &storagepb.StoragePreSignUrlResponse{
            Url: response.URL,
        }, err
    case storagepb.StoragePreSignUrlRequest_WRITE:
        req, err := s.preSignClient.PresignPutObject(ctx, &s3.PutObjectInput{
            Bucket: aws.String(bucketName),
            Key:    aws.String(req.Key),
        }, s3.WithPresignExpires(req.Expiry.AsDuration()))
        if err != nil {
            return nil, status.Errorf(codes.Internal, "failed to generate signed WRITE URL: %v", err)
        }
        return &storagepb.StoragePreSignUrlResponse{
            Url: req.URL,
        }, err
    default:
        return nil, status.Errorf(codes.Unimplemented, "requested operation not supported for pre-signed AWS S3 URLs")
    }
}
```

## Key Design Elements

**Bucket Naming**: Critical that `getS3BucketName()` matches Terraform's naming exactly
**Error Classification**: Separates permission errors from operational errors for better debugging
**Content Type Detection**: Automatically sets proper MIME types for uploads
**Pre-signed URLs**: Enables direct client-to-S3 uploads/downloads bypassing your server
**Credential Resolution**: Uses AWS SDK's automatic credential chain (IAM roles, env vars, etc.)

## Testing the Integration

Once the Terraform plugin is deployed, any application can access the buckets:

### Universal Access Pattern

1. **Terraform creates** bucket named `mystack-photos` with IAM permissions
2. **Any application** can connect using the predictable bucket name
3. **CloudFront discovers** and integrates automatically via resource exports
4. **Credentials** come from standard AWS credential sources

### For Nitric Applications

If you built the optional Nitric runtime plugin:

1. **Nitric runtime** translates storage operations to S3 calls
2. **Applications** use Nitric's storage interface seamlessly
3. **Same underlying buckets** work with both direct AWS access and Nitric abstraction

The modular design means the same S3 buckets work across different application architectures and frameworks.
