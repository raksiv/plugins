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