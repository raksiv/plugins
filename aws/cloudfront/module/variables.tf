variable "nitric" {
  type = object({
    name     = string
    stack_id = string
    # A map of path to origin
    origins = map(object({
      path = string
      base_path = string
      type = string
      domain_name = string
      id = string
      resources = map(string)
    }))
  })
}

variable "waf_enabled" {
  description = "Enable AWS WAF for CloudFront distribution"
  type        = bool
  default     = false
}

variable "waf_managed_rules" {
  description = "List of AWS Managed Rule Groups to enable"
  type = list(object({
    name            = string
    priority        = number
    override_action = string
  }))
  default = [
    {
      name            = "AWSManagedRulesCommonRuleSet"
      priority        = 10
      override_action = "none"
    },
    {
      name            = "AWSManagedRulesKnownBadInputsRuleSet"
      priority        = 20
      override_action = "none"
    }
  ]
}

variable "geo_restriction_type" {
  description = "Type of geo restriction (none, whitelist, blacklist)"
  type        = string
  default     = "none"
  
  validation {
    condition     = contains(["none", "whitelist", "blacklist"], var.geo_restriction_type)
    error_message = "Geo restriction type must be one of: none, whitelist, blacklist."
  }
}

variable "geo_restriction_locations" {
  description = "List of ISO 3166-1 alpha-2 country codes for geo restriction"
  type        = list(string)
  default     = []
}

variable "rate_limit_enabled" {
  description = "Enable rate limiting rules for DDoS protection"
  type        = bool
  default     = true
}

variable "rate_limit_requests_per_5min" {
  description = "Maximum requests per 5-minute period per IP"
  type        = number
  default     = 2000
}
