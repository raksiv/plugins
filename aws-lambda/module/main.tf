terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

# Process cron expressions for EventBridge scheduling
locals {
  # Convert standard cron to AWS CloudWatch format
  split_cron_expression = {
    for key, schedule in var.nitric.schedules : key => split(" ", schedule.cron_expression)
  }

  transformed_cron_expression = {
    for key, fields in local.split_cron_expression : key => [
      for i, field in fields : 
        (i == 4 && fields[2] == "*" && field == "*") ? "?" : field
    ]
  }

  convert_cron_to_aws = {
    for key, schedule in var.nitric.schedules : key => {
      cron_expression = schedule.cron_expression
      path           = schedule.path
      aws_cron       = "cron(${join(" ", local.transformed_cron_expression[key])} *)"
    }
  }

  lambda_name = "${var.nitric.stack_id}-${var.nitric.name}"
}

# Create ECR repository for container images
resource "aws_ecr_repository" "repo" {
  name = var.nitric.name
}

data "aws_ecr_authorization_token" "ecr_auth" {
}

# Get the Docker image provided by Nitric
data "docker_image" "latest" {
  name = var.nitric.image_id
}

# Tag image for ECR
resource "docker_tag" "tag" {
  source_image = length(data.docker_image.latest.repo_digest) > 0 ? data.docker_image.latest.repo_digest : data.docker_image.latest.id
  target_image = aws_ecr_repository.repo.repository_url
}

# Push image to ECR
resource "docker_registry_image" "push" {
  name = aws_ecr_repository.repo.repository_url
  auth_config {
    address  = data.aws_ecr_authorization_token.ecr_auth.proxy_endpoint
    username = data.aws_ecr_authorization_token.ecr_auth.user_name
    password = data.aws_ecr_authorization_token.ecr_auth.password
  }
  triggers = {
    source_image_id = docker_tag.tag.source_image_id
  }
}

# Attach basic execution role
resource "aws_iam_role_policy_attachment" "basic-execution" {
  role       = var.nitric.identities["aws:iam:role"].role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Create Lambda function using container image
resource "aws_lambda_function" "function" {
  function_name = local.lambda_name
  role          = var.nitric.identities["aws:iam:role"].role.arn
  image_uri     = "${aws_ecr_repository.repo.repository_url}@${docker_registry_image.push.sha256_digest}"
  package_type  = "Image"
  timeout       = var.timeout
  memory_size   = var.memory
  
  ephemeral_storage {
    size = var.ephemeral_storage
  }
  
  environment {
    variables = merge(var.environment, var.nitric.env, {
      NITRIC_STACK_ID = var.nitric.stack_id
    })
  }

  architectures = [var.architecture]
  
  depends_on = [docker_registry_image.push]
}

# Create function URL for HTTP access
resource "aws_lambda_function_url" "endpoint" {
  function_name      = aws_lambda_function.function.function_name
  authorization_type = var.function_url_auth_type
  invoke_mode        = "RESPONSE_STREAM"
}

# IAM role for EventBridge scheduler
resource "aws_iam_role" "role" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "scheduler.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "role_policy" {
  role = aws_iam_role.role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = "lambda:InvokeFunction",
        Resource = aws_lambda_function.function.arn
      }
    ]
  })
}

# Create EventBridge schedules for each cron job
resource "aws_scheduler_schedule" "schedule" {
  for_each = var.nitric.schedules
  
  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = local.convert_cron_to_aws[each.key].aws_cron

  target {
    arn      = aws_lambda_function.function.arn
    role_arn = aws_iam_role.role.arn

    input = jsonencode({
        "path" = each.value.path
    })
  }
}