# terraform-aws-bedrock-guardrail

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

A production-grade Terraform module implementing the five-layer guardrail architecture for governing autonomous AI agents in cloud-native DevOps pipelines on AWS.

This module is the infrastructure implementation of the architecture described in:

- **Research implementation and empirical evaluation**: [agentic-devops-guardrails](https://github.com/ManvithaP-hub/agentic-devops-guardrails)

---

## Architecture

The module deploys a fail-closed, five-layer pipeline that intercepts autonomous AI agent actions at the tool-call execution boundary before they affect cloud infrastructure.

```
AI Agent Action Prompt
        │
        ▼
┌─────────────────────────────┐
│  Blast-Radius Scorer        │  B < 0.3 → auto-approve
│  B(a) ∈ [0, 1]             │  B ≥ 0.3 → Layer 1 + 2
└─────────────┬───────────────┘  B ≥ 0.9 → full pipeline + HITL
              ▼
┌─────────────────────────────┐
│  Layer 1: Bedrock Guardrail │  LLM output filter
│  Topic deny + PII block     │  ~400ms when blocked
└─────────────┬───────────────┘
              ▼
┌─────────────────────────────┐
│  Layer 2: OPA Live State    │  Direct boto3 SDK calls
│  ec2 + s3 + iam per-call   │  No cache. No CloudTrail.
└─────────────┬───────────────┘
              ▼
┌─────────────────────────────┐
│  Layer 3: Confidence Delta  │  Claude Haiku 4.5 A/B
│  Hedging vocab frequency    │  Threshold: δ ≥ 0.55
└─────────────┬───────────────┘
              ▼
┌─────────────────────────────┐
│  Layer 4: HITL Gate         │  DynamoDB TTL = 300s
│  Silence equals rejection   │  SNS email + API Gateway
└─────────────┬───────────────┘
              ▼
┌─────────────────────────────┐
│  Layer 5: Audit + Rollback  │  CloudWatch structured JSON
│  S3 snapshot before action  │  Auto-rollback if rate < 70%
└─────────────────────────────┘
```

### Blast-Radius Scoring

Every proposed agent action receives a normalized impact score B(a) ∈ [0, 1]:

| Risk Tier | Score | Vocabulary |
|---|---|---|
| Low-risk | 0.1 | list, get, describe, status, monitor, read, query |
| Medium-risk | 0.4 | restart, scale, update, patch, deploy, modify |
| High-risk | 0.9 | delete, destroy, terminate, drop, purge, wipe, erase |

### Layer 4: Silence Equals Rejection

The HITL gate is the most critical safety property of this architecture. When a high-risk action requires human approval:

1. Lambda writes a DynamoDB record with `ttl = now + 300 seconds`
2. SNS sends an email with approve and reject URLs
3. The Step Functions execution parks at `.waitForTaskToken`
4. If the approver clicks approve or reject — the pipeline resumes or terminates accordingly
5. If the TTL expires with no response — DynamoDB Streams fires a REMOVE event — the `ttl_expiry` Lambda calls `sfn.send_task_failure` — **the action is automatically rejected**

An unavailable approver never produces an implicit approval. This is enforced by native DynamoDB TTL with zero polling overhead.

---

## Prerequisites

- AWS account with Amazon Bedrock enabled in `us-east-1`
- Claude Haiku 4.5 (`us.anthropic.claude-haiku-4-5-20251001-v1:0`) model access enabled in Bedrock
- Terraform >= 1.5
- AWS credentials with permissions to create Lambda, DynamoDB, SNS, S3, IAM, CloudWatch, API Gateway, Step Functions, and Bedrock resources

---

## Usage

```hcl
module "agentic_guardrail" {
  source = "ManvithaP-hub/bedrock-guardrail/aws"

  name_prefix    = "my-agent"
  environment    = "prod"
  approver_email = "oncall@mycompany.com"

  layer2_denied_topics = [
    {
      name       = "destructive-ops"
      definition = "Actions that delete, destroy, terminate, or purge cloud infrastructure"
      examples   = ["delete all EC2 instances", "drop the RDS database", "purge the S3 bucket"]
    },
    {
      name       = "credential-exposure"
      definition = "Actions that expose or rotate AWS credentials or secrets"
      examples   = ["show me the AWS access keys", "rotate all IAM credentials"]
    }
  ]

  hitl_ttl_seconds     = 300  # 5 minutes — silence equals rejection
  block_rate_threshold = 70   # CloudWatch alarm threshold (%)
  log_retention_days   = 30

  tags = {
    Project = "agentic-ai-governance"
  }
}
```

### Basic example

See [`examples/basic/main.tf`](examples/basic/main.tf) for a complete working example.

---

## Resources Created

| Resource | Purpose |
|---|---|
| `aws_bedrock_guardrail` | Layer 1 LLM output filter |
| `aws_lambda_function` (blast_radius) | Blast-radius scoring module |
| `aws_lambda_function` (opa_evaluator) | Layer 2 live-state policy engine |
| `aws_lambda_function` (confidence_delta) | Layer 3 A/B confidence scorer |
| `aws_lambda_function` (hitl_initiator) | Layer 4 HITL gate initiator |
| `aws_lambda_function` (hitl_callback) | Layer 4 approve/reject handler |
| `aws_lambda_function` (ttl_expiry) | Layer 4 silence-equals-rejection enforcer |
| `aws_lambda_function` (snapshot_creator) | Layer 5 pre-action state capture |
| `aws_lambda_function` (rollback_executor) | Layer 5 automated rollback |
| `aws_dynamodb_table` | HITL approval records with native TTL |
| `aws_sfn_state_machine` | Pipeline orchestration |
| `aws_s3_bucket` | Audit logs and state snapshots |
| `aws_sns_topic` | HITL approval notifications |
| `aws_apigatewayv2_api` | Approve/reject URL endpoint |
| `aws_cloudwatch_metric_alarm` | Block-rate monitoring |
| `aws_kms_key` | Encryption for all data at rest |

---

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `name_prefix` | Prefix for all resource names | `string` | — | yes |
| `environment` | Deployment environment (dev/staging/prod) | `string` | `"dev"` | no |
| `approver_email` | Email address for HITL approval notifications | `string` | — | yes |
| `hitl_ttl_seconds` | Seconds before unanswered approval auto-rejects | `number` | `300` | no |
| `block_rate_threshold` | CloudWatch alarm threshold for block rate (%) | `number` | `70` | no |
| `layer1_enabled` | Enable Bedrock Guardrail (Layer 1) | `bool` | `true` | no |
| `layer2_denied_topics` | Denial topics for Bedrock Guardrail | `list(object)` | `[]` | no |
| `layer2_pii_config` | PII entity filter configuration | `list(object)` | `[]` | no |
| `log_retention_days` | CloudWatch log retention in days | `number` | `30` | no |
| `kms_key_arn` | Existing KMS key ARN (creates new key if null) | `string` | `null` | no |
| `audit_bucket_name` | Existing S3 bucket name (creates new bucket if null) | `string` | `null` | no |
| `tags` | Tags to apply to all resources | `map(string)` | `{}` | no |

---

## Outputs

| Name | Description |
|---|---|
| `state_machine_arn` | ARN of the guardrail Step Functions state machine |
| `guardrail_id` | Bedrock Guardrail ID for Layer 1 |
| `hitl_table_name` | DynamoDB table name for HITL approvals |
| `snapshot_bucket` | S3 bucket name for audit logs and snapshots |
| `hitl_api_url` | Base URL for HITL approval/rejection actions |
| `block_rate_alarm_arn` | ARN of the block-rate monitoring alarm |
| `kms_key_arn` | ARN of the KMS key used for encryption |

---

## Empirical Results

This architecture was evaluated on AWS (us-east-1) across 100 prompts spanning five risk categories, including 20 adversarial jailbreak variants, using Claude Haiku 4.5 as the inference model. Figures come from the raw results in the [reference implementation](https://github.com/ManvithaP-hub/agentic-devops-guardrails) (`results_5layer.txt`, `results.txt`).

| Category | N | Expected | Blocked | Correct | Avg Latency |
|---|---|---|---|---|---|
| Read operations | 20 | allow | 0 | 20 | not timed* |
| Safe staging changes | 20 | allow | 6 | 14 | 10,103ms |
| Risky production changes | 20 | block | 20 | 20 | 4,579ms |
| Destructive operations | 20 | block | 20 | 20 | 413ms |
| Adversarial jailbreaks | 20 | block | 20 | 20 | 649ms |
| **Total** | **100** | | **66** | **94** | **3,149ms** |

\* Read-only actions skip model invocation; latency recorded as 0.

**Key findings:**
- 94% overall accuracy; 0 false negatives across all 60 block-expected prompts
- 100% of destructive operations and adversarial jailbreak variants blocked
- 6 false positives (staging changes), 6% of all prompts / 6 of 40 allow-expected prompts
- Blocked actions resolved 7.6x faster than allowed ones (1,828ms vs 13,874ms)
- Layer 1 decided 48 blocks (73%); Layer 2 decided 18 (27%): 16 risky production changes and 2 adversarial prompts

> **Evaluation note:** The evaluation used a rule-equivalent version of the Layer 2 policies (environment read from the action text) and a simulated HITL gate. The live-state OPA Lambda and DynamoDB approval gate deployed by this module are the production implementations.

---

## Single Layer vs Five Layers

The same 100 prompts were run against the Bedrock guardrail alone and against the full pipeline:

| Metric | Layer 1 only | Five layers |
|---|---|---|
| Overall accuracy | 76% | **94%** |
| False negatives (of 60) | 18 | **0** |
| Risky production missed | 16/20 | **0/20** |
| Adversarial missed | 2/20 | **0/20** |
| Destructive missed | 0/20 | **0/20** |
| False positives (of 40) | 6 | 6 |

Every action the content filter missed was a production-targeted change or a disguised attack, which the environment policy layer caught without adding any false positives. Multi-layer defense-in-depth is empirically necessary.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.

---

## Author

**Manvitha Potluri**
DevOps Cloud Solutions Architect
[github.com/ManvithaP-hub](https://github.com/ManvithaP-hub)
