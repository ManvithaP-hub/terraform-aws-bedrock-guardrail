data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "sfn_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

locals {
  base_lambda_policy = [
    {
      Sid      = "KMS"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource = local.kms_key_arn
    },
    {
      Sid      = "XRay"
      Effect   = "Allow"
      Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      Resource = "*"
    },
    {
      Sid    = "CW"
      Effect = "Allow"
      Action = ["cloudwatch:PutMetricData"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "cloudwatch:namespace" = local.metric_namespace
        }
      }
    },
  ]
}

# Layer 1 - Blast radius scorer role
resource "aws_iam_role" "blast_radius" {
  name               = "${local.name_prefix}-blast-radius-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "blast_radius_basic" {
  role       = aws_iam_role.blast_radius.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "blast_radius" {
  role   = aws_iam_role.blast_radius.id
  name   = "inline"
  policy = jsonencode({ Version = "2012-10-17", Statement = local.base_lambda_policy })
}

# Layer 2 - OPA evaluator role
resource "aws_iam_role" "opa_evaluator" {
  name               = "${local.name_prefix}-opa-evaluator-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "opa_evaluator_basic" {
  role       = aws_iam_role.opa_evaluator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "opa_evaluator" {
  role = aws_iam_role.opa_evaluator.id
  name = "inline"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.base_lambda_policy, [
      {
        Sid      = "EC2Read"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid      = "S3Read"
        Effect   = "Allow"
        Action   = ["s3:ListAllMyBuckets"]
        Resource = "*"
      },
      {
        Sid      = "IAMRead"
        Effect   = "Allow"
        Action   = ["iam:ListRoles"]
        Resource = "*"
      },
    ])
  })
}

# Layer 3 - Confidence delta scorer role
resource "aws_iam_role" "confidence_delta" {
  name               = "${local.name_prefix}-confidence-delta-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "confidence_delta_basic" {
  role       = aws_iam_role.confidence_delta.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "confidence_delta" {
  role = aws_iam_role.confidence_delta.id
  name = "inline"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.base_lambda_policy, [
      {
        Sid      = "BedrockInvoke"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${local.region}::foundation-model/${var.confidence_delta_model_id}"
      },
      {
        Sid      = "BedrockGuardrail"
        Effect   = "Allow"
        Action   = ["bedrock:ApplyGuardrail"]
        Resource = aws_bedrock_guardrail.main.guardrail_arn
      },
    ])
  })
}

# Layer 4 - HITL initiator role
resource "aws_iam_role" "hitl_initiator" {
  name               = "${local.name_prefix}-hitl-initiator-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "hitl_initiator_basic" {
  role       = aws_iam_role.hitl_initiator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "hitl_initiator" {
  role = aws_iam_role.hitl_initiator.id
  name = "inline"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.base_lambda_policy, [
      {
        Sid      = "DDBWrite"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.hitl_approvals.arn
      },
      {
        Sid      = "SNSPublish"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.hitl.arn
      },
    ])
  })
}

# Layer 4 - HITL callback role
resource "aws_iam_role" "hitl_callback" {
  name               = "${local.name_prefix}-hitl-callback-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "hitl_callback_basic" {
  role       = aws_iam_role.hitl_callback.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "hitl_callback" {
  role = aws_iam_role.hitl_callback.id
  name = "inline"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.base_lambda_policy, [
      {
        Sid      = "DDBUpdate"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.hitl_approvals.arn
      },
      {
        Sid      = "SFNCallback"
        Effect   = "Allow"
        Action   = ["states:SendTaskSuccess", "states:SendTaskFailure"]
        Resource = "*"
      },
    ])
  })
}

# Layer 4 - TTL expiry handler role
resource "aws_iam_role" "ttl_expiry" {
  name               = "${local.name_prefix}-ttl-expiry-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ttl_expiry_basic" {
  role       = aws_iam_role.ttl_expiry.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "ttl_expiry" {
  role = aws_iam_role.ttl_expiry.id
  name = "inline"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.base_lambda_policy, [
      {
        Sid    = "DDBStream"
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams"
        ]
        Resource = aws_dynamodb_table.hitl_approvals.stream_arn
      },
      {
        Sid      = "SFNFailure"
        Effect   = "Allow"
        Action   = ["states:SendTaskFailure"]
        Resource = "*"
      },
    ])
  })
}

# Layer 5 - Snapshot creator role
resource "aws_iam_role" "snapshot_creator" {
  name               = "${local.name_prefix}-snapshot-creator-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "snapshot_creator_basic" {
  role       = aws_iam_role.snapshot_creator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "snapshot_creator" {
  role = aws_iam_role.snapshot_creator.id
  name = "inline"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.base_lambda_policy, [
      {
        Sid      = "S3Write"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.snapshots.arn}/snapshots/*"
      },
      {
        Sid    = "StateRead"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "s3:ListAllMyBuckets",
          "iam:ListRoles",
          "cloudwatch:GetMetricData"
        ]
        Resource = "*"
      },
    ])
  })
}

# Layer 5 - Rollback executor role
resource "aws_iam_role" "rollback_executor" {
  name               = "${local.name_prefix}-rollback-executor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "rollback_executor_basic" {
  role       = aws_iam_role.rollback_executor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "rollback_executor" {
  role = aws_iam_role.rollback_executor.id
  name = "inline"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.base_lambda_policy, [
      {
        Sid      = "S3Read"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.snapshots.arn, "${aws_s3_bucket.snapshots.arn}/*"]
      },
      {
        Sid    = "EC2Rollback"
        Effect = "Allow"
        Action = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/ManagedByGuardrail" = "true"
          }
        }
      },
      {
        Sid      = "SNSAlert"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.hitl.arn
      },
    ])
  })
}

# Step Functions orchestrator role
resource "aws_iam_role" "sfn" {
  name               = "${local.name_prefix}-sfn-guardrail-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "sfn" {
  role = aws_iam_role.sfn.id
  name = "inline"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeLambdas"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.blast_radius.arn,
          aws_lambda_function.opa_evaluator.arn,
          aws_lambda_function.confidence_delta.arn,
          aws_lambda_function.hitl_initiator.arn,
          aws_lambda_function.snapshot_creator.arn,
        ]
      },
      {
        Sid      = "BedrockLayer1"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${local.region}::foundation-model/${var.confidence_delta_model_id}"
      },
      {
        Sid    = "CWLogsDelivery"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Sid    = "XRay"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      },
      {
        Sid      = "KMS"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = local.kms_key_arn
      },
    ]
  })
}
