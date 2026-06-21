# ── Core ─────────────────────────────────────────────────────────────────────
variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "environment" {
  description = "Deployment environment: dev | staging | prod."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

# ── Blast-radius routing thresholds  ─────────────────────────────
variable "blast_radius_auto_approve_threshold" {
  description = "B < this value → auto-approve, skip all layers."
  type        = number
  default     = 0.3
}

variable "blast_radius_hitl_threshold" {
  description = "B ≥ this value → mandatory Layer 4 HITL gate."
  type        = number
  default     = 0.9
}

# ── Layer 1 – Bedrock Guardrail ───────────────────────────────────────────────
variable "layer1_content_filters" {
  description = "Bedrock content filter configuration."
  type = list(object({
    type            = string
    input_strength  = string
    output_strength = string
  }))
  default = [
    { type = "HATE",       input_strength = "HIGH",   output_strength = "HIGH"   },
    { type = "VIOLENCE",   input_strength = "HIGH",   output_strength = "HIGH"   },
    { type = "MISCONDUCT", input_strength = "HIGH",   output_strength = "HIGH"   },
    { type = "PROMPT_ATTACK", input_strength = "HIGH", output_strength = "NONE"  },
  ]
}

# ── Layer 2 – OPA live state evaluation ───────────────────────────────────────
variable "opa_version" {
  description = "OPA binary version to download for the Lambda package."
  type        = string
  default     = "v0.65.0"
}

variable "opa_policy_path" {
  description = "Path to the OPA Rego policy file bundled with the evaluator Lambda."
  type        = string
  default     = "policies/guardrail.rego"
}

# ── Layer 3 – Confidence delta scorer ────────────────────────────────────────
variable "confidence_delta_model_id" {
  description = "Bedrock model ID invoked twice for A/B comparison. Must be Claude 3 Haiku."
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
}

variable "confidence_delta_threshold" {
  description = "Hedging-vocabulary delta score ≥ this value → escalate to Layer 4."
  type        = number
  default     = 0.55
}

# ── Layer 4 – HITL gate ───────────────────────────────────────────────────────
variable "hitl_ttl_seconds" {
  description = "DynamoDB TTL window in seconds. Expiry = auto-rejection. Silence equals rejection."
  type        = number
  default     = 300
}

variable "hitl_approver_email" {
  description = "Email address that receives HITL approve/reject notification via SNS."
  type        = string
}

# ── Layer 5 – CloudWatch audit + S3 rollback ─────────────────────────────────
variable "block_rate_alarm_threshold" {
  description = "Fractional block rate. Alarm fires when rate drops BELOW this value in any 5-min window."
  type        = number
  default     = 0.70
}

variable "post_execution_monitor_seconds" {
  description = "Health monitoring window after each executed action (seconds)."
  type        = number
  default     = 300
}

# ── Shared infrastructure ─────────────────────────────────────────────────────
variable "kms_key_arn" {
  description = "Existing CMK ARN. When null a dedicated key is created."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch log group retention (days)."
  type        = number
  default     = 30
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for operational alarms. When null no alarm actions are set."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
