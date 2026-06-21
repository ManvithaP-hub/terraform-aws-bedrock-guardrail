data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix      = "${var.name_prefix}-${var.environment}"
  common_tags      = merge(var.tags, { Module = "bedrock-guardrail-stack", Environment = var.environment, ManagedBy = "Terraform" })
  kms_key_arn      = var.kms_key_arn != null ? var.kms_key_arn : aws_kms_key.main[0].arn
  metric_namespace = "BedrockGuardrail/${local.name_prefix}"
  account_id       = data.aws_caller_identity.current.account_id
  region           = data.aws_region.current.name
}

# ── KMS ──────────────────────────────────────────────────────────────────────
resource "aws_kms_key" "main" {
  count                   = var.kms_key_arn == null ? 1 : 0
  description             = "${local.name_prefix} guardrail stack CMK"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Root", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }, Action = "kms:*", Resource = "*" },
      { Sid = "CWLogs", Effect = "Allow", Principal = { Service = "logs.${local.region}.amazonaws.com" },
        Action = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"], Resource = "*",
        Condition = { ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${local.region}:${local.account_id}:*" } } },
      { Sid = "DynamoDB", Effect = "Allow", Principal = { Service = "dynamodb.amazonaws.com" },
        Action = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"], Resource = "*" },
    ]
  })
  tags = local.common_tags
}

resource "aws_kms_alias" "main" {
  count         = var.kms_key_arn == null ? 1 : 0
  name          = "alias/${local.name_prefix}-guardrail"
  target_key_id = aws_kms_key.main[0].key_id
}

# ── Layer 1 – Bedrock Guardrail ───────────────────────────────────────────────
resource "aws_bedrock_guardrail" "main" {
  name                      = "${local.name_prefix}-guardrail"
  description               = "Layer 1 LLM output filter – five-layer agentic guardrail "
  blocked_input_messaging   = "Action request blocked by content policy."
  blocked_outputs_messaging = "Response blocked by content policy."
  kms_key_arn               = local.kms_key_arn

  dynamic "content_policy_config" {
    for_each = length(var.layer1_content_filters) > 0 ? [1] : []
    content {
      dynamic "filters_config" {
        for_each = var.layer1_content_filters
        content {
          type            = filters_config.value.type
          input_strength  = filters_config.value.input_strength
          output_strength = filters_config.value.output_strength
        }
      }
    }
  }

  sensitive_information_policy_config {
    pii_entities_config { type = "AWS_ACCESS_KEY", action = "BLOCK" }
    pii_entities_config { type = "AWS_SECRET_KEY", action = "BLOCK" }
  }

  tags = local.common_tags
}

resource "aws_bedrock_guardrail_version" "main" {
  guardrail_arn = aws_bedrock_guardrail.main.guardrail_arn
  description   = "Managed by Terraform"
}

# ── Layer 4 – DynamoDB HITL table ────────────────────────────────────────────
# Native DynamoDB TTL expiry IS the rejection mechanism.
# TTL deletion triggers DynamoDB Streams → ttl_expiry Lambda → sfn.send_task_failure.
# Zero polling. Silence equals rejection.
resource "aws_dynamodb_table" "hitl_approvals" {
  name         = "${local.name_prefix}-hitl-approvals"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "approval_id"

  attribute {
    name = "approval_id"
    type = "S"
  }

  # TTL attribute – DynamoDB deletes the record at expiry.
  # The deletion event propagates to DynamoDB Streams and triggers auto-rejection.
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # Streams MUST be enabled: the ttl_expiry Lambda reads REMOVE events.
  # NEW_AND_OLD_IMAGES required to recover the task_token from OldImage.
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.kms_key_arn
  }

  point_in_time_recovery { enabled = true }

  tags = local.common_tags
}

# ── Layer 5 – S3 snapshot bucket ─────────────────────────────────────────────
resource "aws_s3_bucket" "snapshots" {
  bucket = "${local.name_prefix}-action-snapshots-${local.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "snapshots" {
  bucket                  = aws_s3_bucket.snapshots.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id
  rule {
    id     = "expire-old-snapshots"
    status = "Enabled"
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

# ── Layer 4 – SNS HITL notification topic ────────────────────────────────────
resource "aws_sns_topic" "hitl" {
  name              = "${local.name_prefix}-hitl-notifications"
  kms_master_key_id = local.kms_key_arn
  tags              = local.common_tags
}

resource "aws_sns_topic_subscription" "hitl_email" {
  topic_arn = aws_sns_topic.hitl.arn
  protocol  = "email"
  endpoint  = var.hitl_approver_email
}

# ── Layer 4 – API Gateway (HITL approve/reject URLs) ─────────────────────────
resource "aws_api_gateway_rest_api" "hitl" {
  name        = "${local.name_prefix}-hitl-api"
  description = "HITL gate approve/reject callback for the five-layer guardrail"
  tags        = local.common_tags
}

# /approve/{approval_id}
resource "aws_api_gateway_resource" "approve" {
  rest_api_id = aws_api_gateway_rest_api.hitl.id
  parent_id   = aws_api_gateway_rest_api.hitl.root_resource_id
  path_part   = "approve"
}
resource "aws_api_gateway_resource" "approve_id" {
  rest_api_id = aws_api_gateway_rest_api.hitl.id
  parent_id   = aws_api_gateway_resource.approve.id
  path_part   = "{approval_id}"
}
resource "aws_api_gateway_method" "approve" {
  rest_api_id   = aws_api_gateway_rest_api.hitl.id
  resource_id   = aws_api_gateway_resource.approve_id.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "approve" {
  rest_api_id             = aws_api_gateway_rest_api.hitl.id
  resource_id             = aws_api_gateway_resource.approve_id.id
  http_method             = aws_api_gateway_method.approve.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.hitl_callback.invoke_arn
}

# /reject/{approval_id}
resource "aws_api_gateway_resource" "reject" {
  rest_api_id = aws_api_gateway_rest_api.hitl.id
  parent_id   = aws_api_gateway_rest_api.hitl.root_resource_id
  path_part   = "reject"
}
resource "aws_api_gateway_resource" "reject_id" {
  rest_api_id = aws_api_gateway_rest_api.hitl.id
  parent_id   = aws_api_gateway_resource.reject.id
  path_part   = "{approval_id}"
}
resource "aws_api_gateway_method" "reject" {
  rest_api_id   = aws_api_gateway_rest_api.hitl.id
  resource_id   = aws_api_gateway_resource.reject_id.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "reject" {
  rest_api_id             = aws_api_gateway_rest_api.hitl.id
  resource_id             = aws_api_gateway_resource.reject_id.id
  http_method             = aws_api_gateway_method.reject.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.hitl_callback.invoke_arn
}

resource "aws_api_gateway_deployment" "hitl" {
  rest_api_id = aws_api_gateway_rest_api.hitl.id
  depends_on = [
    aws_api_gateway_integration.approve,
    aws_api_gateway_integration.reject,
  ]
  lifecycle { create_before_destroy = true }
}

resource "aws_api_gateway_stage" "hitl" {
  rest_api_id   = aws_api_gateway_rest_api.hitl.id
  deployment_id = aws_api_gateway_deployment.hitl.id
  stage_name    = var.environment
  tags          = local.common_tags
}

locals {
  approve_url_base = "https://${aws_api_gateway_rest_api.hitl.id}.execute-api.${local.region}.amazonaws.com/${var.environment}/approve"
  reject_url_base  = "https://${aws_api_gateway_rest_api.hitl.id}.execute-api.${local.region}.amazonaws.com/${var.environment}/reject"
}

resource "aws_lambda_permission" "hitl_callback_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hitl_callback.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.hitl.execution_arn}/*/*"
}
