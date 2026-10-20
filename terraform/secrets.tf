# Created empty. The host generates the first four on first boot and writes them here; an operator puts the Google
# client secret (if used). No value ever passes through Terraform, its state, a command line or a log.
resource "aws_secretsmanager_secret" "vpn" {
  for_each                = toset(local.secret_names)
  name                    = "${local.secret_prefix}${each.key}"
  recovery_window_in_days = 7
}
