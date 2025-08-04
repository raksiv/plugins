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