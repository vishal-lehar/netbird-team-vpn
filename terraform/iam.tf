# The host's role: Session Manager (no SSH), its own secrets, its own logs. Deliberately not
# AmazonSSMManagedInstanceCore, which also allows reading every SSM parameter in the account.

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpn" {
  name               = "${var.name}-ec2"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

data "aws_iam_policy_document" "vpn" {
  statement {
    sid = "SessionManagerAgent"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "OwnSecrets"
    actions   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]
    resources = [for s in aws_secretsmanager_secret.vpn : s.arn]
  }

  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [for g in aws_cloudwatch_log_group.vpn : "${g.arn}:*"]
  }
}

resource "aws_iam_role_policy" "vpn" {
  name   = "vpn"
  role   = aws_iam_role.vpn.id
  policy = data.aws_iam_policy_document.vpn.json
}

resource "aws_iam_instance_profile" "vpn" {
  name = "${var.name}-ec2"
  role = aws_iam_role.vpn.name
}
