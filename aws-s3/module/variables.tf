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