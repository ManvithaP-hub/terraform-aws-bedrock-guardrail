locals {
  lambda_defaults = {
    runtime     = "python3.12"
    kms_key_arn = local.kms_key_arn
    environment = {
      variables = {
        NAME_PREFIX      = local.name_prefix
        ENVIRONMENT      = var.environment
        METRIC_NAMESPACE = local.metric_namespace
        AUDIT_BUCKET     = local.audit_bucket_name
      }
    }
  }
}

# Lambda zip archives
data "archive_file" "blast_radius" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/blast_radius"
  output_path = "${path.module}/.terraform/zips/blast_radius.zip"
}

data "archive_file" "opa_evaluator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/opa_evaluator"
  output_path = "${path.module}/.terraform/zips/opa_evaluator.zip"
  depends_on  = [null_resource.opa_policy_copy]
}

data "archive_file" "confidence_delta" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/confidence_delta"
  output_path = "${path.module}/.terraform/zips/confidence_delta.zip"
}

data "archive_file" "hitl_initiator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/hitl_initiator"
  output_path = "${path.module}/.terraform/zips/hitl_initiator.zip"
}

data "archive_file" "hitl_callback" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/hitl_callback"
  output_path = "${path.module}/.terraform/zips/hitl_callback.zip"
}

data "archive_file" "ttl_expiry" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/ttl_expiry"
  output_path = "${path.module}/.terraform/zips/ttl_expiry.zip"
}

data "archive_file" "snapshot_creator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/snapshot_creator"
  output_path = "${path.module}/.terraform/zips/snapshot_creator.zip"
}

data "archive_file" "rollback_executor" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/rollback_executor"
  output_path = "${path.module}/.terraform/zips/rollback_executor.zip"
}

# Copy OPA policy into the evaluator Lambda package
resource "null_resource" "opa_policy_copy" {
  triggers = {
    policy_hash = filemd5("${path.module}/policies/guardrail.rego")
  }
  provisioner "local-exec" {
    command = "cp ${path.module}/policies/guardrail.rego ${path.module}/lambda/opa_evaluator/guardrail.rego"
  }
}

# Layer 1 - Blast radius scorer
resource "aws_lambda_function" "blast_radius" {
  function_name    = "${local.name_prefix}-blast-radius"
  description      = "Blast-radius scoring module: classify action vocabulary and compute B(a) in [0,1]"
  role             = aws_iam_role.blast_radius.arn
  filename         = data.archive_file.blast_radius.output_path
  source_code_hash = data.archive_file.blast_radius.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = local.lambda_defaults.runtime
  timeout          = 10
  memory_size      = 256
  kms_key_arn      = local.lambda_defaults.kms_key_arn

  environment {
    variables = local.lambda_defaults.environment.variables
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# Layer 2 - OPA evaluator against live AWS state
resource "aws_lambda_function" "opa_evaluator" {
  function_name    = "${local.name_prefix}-opa-evaluator"
  description      = "Layer 2: OPA policy evaluation against live AWS state (boto3 direct SDK, no cache)"
  role             = aws_iam_role.opa_evaluator.arn
  filename         = data.archive_file.opa_evaluator.output_path
  source_code_hash = data.archive_file.opa_evaluator.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = local.lambda_defaults.runtime
  timeout          = 30
  memory_size      = 512
  kms_key_arn      = local.lambda_defaults.kms_key_arn

  environment {
    variables = local.lambda_defaults.environment.variables
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# Layer 3 - Confidence delta scorer
resource "aws_lambda_function" "confidence_delta" {
  function_name    = "${local.name_prefix}-confidence-delta"
  description      = "Layer 3: Invoke Claude 3 Haiku twice (with/without guardrail) and compute hedging delta"
  role             = aws_iam_role.confidence_delta.arn
  filename         = data.archive_file.confidence_delta.output_path
  source_code_hash = data.archive_file.confidence_delta.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = local.lambda_defaults.runtime
  timeout          = 60
  memory_size      = 512
  kms_key_arn      = local.lambda_defaults.kms_key_arn

  environment {
    variables = merge(local.lambda_defaults.environment.variables, {
      GUARDRAIL_ID         = aws_bedrock_guardrail.main.guardrail_id
      GUARDRAIL_VERSION    = aws_bedrock_guardrail.main.version
      CONFIDENCE_MODEL_ID  = var.confidence_delta_model_id
      DELTA_THRESHOLD      = tostring(var.confidence_delta_threshold)
    })
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# Layer 4 - HITL initiator
resource "aws_lambda_function" "hitl_initiator" {
  function_name    = "${local.name_prefix}-hitl-initiator"
  description      = "Layer 4: Write HITL record to DynamoDB (TTL=+300s) and send SNS approve/reject email"
  role             = aws_iam_role.hitl_initiator.arn
  filename         = data.archive_file.hitl_initiator.output_path
  source_code_hash = data.archive_file.hitl_initiator.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = local.lambda_defaults.runtime
  timeout          = 15
  memory_size      = 256
  kms_key_arn      = local.lambda_defaults.kms_key_arn

  environment {
    variables = merge(local.lambda_defaults.environment.variables, {
      HITL_TABLE_NAME  = aws_dynamodb_table.hitl_approvals.name
      HITL_SNS_ARN     = aws_sns_topic.hitl.arn
      HITL_TTL_SECONDS = tostring(var.hitl_ttl_seconds)
      APPROVE_BASE_URL = "${aws_apigatewayv2_api.hitl.api_endpoint}/approve"
      REJECT_BASE_URL  = "${aws_apigatewayv2_api.hitl.api_endpoint}/reject"
    })
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# Layer 4 - HITL callback (approve/reject URL handler)
resource "aws_lambda_function" "hitl_callback" {
  function_name    = "${local.name_prefix}-hitl-callback"
  description      = "Layer 4: Handle approve/reject URL clicks and call sfn.send_task_success/failure"
  role             = aws_iam_role.hitl_callback.arn
  filename         = data.archive_file.hitl_callback.output_path
  source_code_hash = data.archive_file.hitl_callback.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = local.lambda_defaults.runtime
  timeout          = 10
  memory_size      = 256
  kms_key_arn      = local.lambda_defaults.kms_key_arn

  environment {
    variables = merge(local.lambda_defaults.environment.variables, {
      HITL_TABLE_NAME = aws_dynamodb_table.hitl_approvals.name
    })
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# Layer 4 - TTL expiry handler (DynamoDB Streams silence=rejection enforcer)
resource "aws_lambda_function" "ttl_expiry" {
  function_name    = "${local.name_prefix}-ttl-expiry"
  description      = "Layer 4: Auto-reject on DynamoDB TTL expiry. Silence equals rejection."
  role             = aws_iam_role.ttl_expiry.arn
  filename         = data.archive_file.ttl_expiry.output_path
  source_code_hash = data.archive_file.ttl_expiry.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = local.lambda_defaults.runtime
  timeout          = 30
  memory_size      = 256
  kms_key_arn      = local.lambda_defaults.kms_key_arn

  environment {
    variables = local.lambda_defaults.environment.variables
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

resource "aws_lambda_event_source_mapping" "ttl_expiry_stream" {
  event_source_arn  = aws_dynamodb_table.hitl_approvals.stream_arn
  function_name     = aws_lambda_function.ttl_expiry.arn
  starting_position = "LATEST"
  filter_criteria {
    filter {
      pattern = jsonencode({ eventName = ["REMOVE"] })
    }
  }
}

# Layer 5 - Snapshot creator
resource "aws_lambda_function" "snapshot_creator" {
  function_name    = "${local.name_prefix}-snapshot-creator"
  description      = "Layer 5: Capture S3 state snapshot before each approved action executes"
  role             = aws_iam_role.snapshot_creator.arn
  filename         = data.archive_file.snapshot_creator.output_path
  source_code_hash = data.archive_file.snapshot_creator.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = local.lambda_defaults.runtime
  timeout          = 30
  memory_size      = 512
  kms_key_arn      = local.lambda_defaults.kms_key_arn

  environment {
    variables = merge(local.lambda_defaults.environment.variables, {
      SNAPSHOT_BUCKET = local.audit_bucket_name
    })
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# Layer 5 - Rollback executor
resource "aws_lambda_function" "rollback_executor" {
  function_name    = "${local.name_prefix}-rollback-executor"
  description      = "Layer 5: Restore pre-action state from S3 snapshot on CloudWatch alarm"
  role             = aws_iam_role.rollback_executor.arn
  filename         = data.archive_file.rollback_executor.output_path
  source_code_hash = data.archive_file.rollback_executor.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = local.lambda_defaults.runtime
  timeout          = 60
  memory_size      = 512
  kms_key_arn      = local.lambda_defaults.kms_key_arn

  environment {
    variables = merge(local.lambda_defaults.environment.variables, {
      SNAPSHOT_BUCKET  = local.audit_bucket_name
      ALERT_SNS_ARN    = aws_sns_topic.hitl.arn
    })
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# CloudWatch alarm triggers rollback
resource "aws_cloudwatch_metric_alarm" "rollback_trigger" {
  alarm_name          = "${local.name_prefix}-rollback-trigger"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "BlockRate"
  namespace           = local.metric_namespace
  period              = 300
  statistic           = "Average"
  threshold           = var.block_rate_threshold
  alarm_description   = "Block rate dropped below ${var.block_rate_threshold}% - triggering rollback review"
  alarm_actions       = [aws_sns_topic.hitl.arn]
  tags                = local.common_tags
}
