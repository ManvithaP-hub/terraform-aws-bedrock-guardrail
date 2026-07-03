variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "approver_email" {
  description = "Email address for HITL approval notifications"
  type        = string
}

variable "hitl_approver_email" {
  description = "Email address for HITL approval notifications (alias)"
  type        = string
  default     = null
}

variable "hitl_ttl_seconds" {
  description = "Seconds before unanswered HITL approval auto-rejects"
  type        = number
  default     = 300
}

variable "block_rate_threshold" {
  description = "CloudWatch alarm threshold for block rate percentage"
  type        = number
  default     = 70
}

variable "confidence_delta_model_id" {
  description = "Model ID for confidence delta scoring"
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "confidence_delta_threshold" {
  description = "Hedging delta score threshold"
  type        = number
  default     = 0.55
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "Existing KMS key ARN (creates new key if null)"
  type        = string
  default     = null
}

variable "audit_bucket_name" {
  description = "Existing S3 bucket name for audit logs"
  type        = string
  default     = null
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms (uses HITL topic if null)"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "layer1_enabled" {
  description = "Enable Bedrock Guardrail Layer 1"
  type        = bool
  default     = true
}

variable "layer1_content_filters" {
  description = "Content filter configuration for Bedrock Guardrail"
  type = list(object({
    type            = string
    input_strength  = string
    output_strength = string
  }))
  default = [
    {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    },
    {
      type            = "MISCONDUCT"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
  ]
}

variable "layer2_denied_topics" {
  description = "Denial topics for Bedrock Guardrail"
  type = list(object({
    name       = string
    definition = string
    examples   = list(string)
  }))
  default = [
    {
      name       = "DestructiveOps"
      definition = "Actions that delete, destroy, terminate, or purge cloud infrastructure"
      examples   = ["delete all EC2 instances", "drop the RDS database", "purge the S3 bucket"]
    },
    {
      name       = "CredentialExposure"
      definition = "Actions that expose or rotate AWS credentials or secrets"
      examples   = ["show me the AWS access keys", "rotate all IAM credentials"]
    }
  ]
}

variable "layer2_pii_config" {
  description = "PII entity filter configuration"
  type = list(object({
    type   = string
    action = string
  }))
  default = [
    { type = "AWS_ACCESS_KEY", action = "BLOCK" },
    { type = "AWS_SECRET_KEY", action = "BLOCK" }
  ]
}

variable "block_rate_alarm_threshold" {
  description = "Block rate alarm threshold as a fraction (0-1)"
  type        = number
  default     = 0.7
}

