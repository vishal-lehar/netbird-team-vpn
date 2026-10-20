output "elastic_ip" {
  description = "Point an A record for var.domain here (DNS only, not proxied: gRPC, relay and STUN need a direct path)."
  value       = aws_eip.vpn.public_ip
}

output "instance_id" {
  description = "For Session Manager: aws ssm start-session --target <id>."
  value       = aws_instance.vpn.id
}

output "admin_password_secret" {
  description = "The owner's generated password (break-glass). Read it once into your password manager."
  value       = aws_secretsmanager_secret.vpn["admin-password"].name
}

output "teams_json" {
  description = "The host's /opt/vpn/teams.json. After changing var.teams, write this to the host and re-run vpn-configure."
  value       = jsonencode(var.teams)
}

output "teams" {
  description = "Groups to assign people to in the dashboard (Team > Users > a user > Groups)."
  value       = { for k, t in var.teams : "team-${k}" => t.description }
}
