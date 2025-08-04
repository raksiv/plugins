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