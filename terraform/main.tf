# One hardened host: NetBird (management, signal, relay, embedded identity provider), its dashboard, Traefik for TLS,
# and a routing peer that carries each team's private networks. See README.md for the design.

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_region" "current" {}

locals {
  secret_prefix = "${var.name}-"
  secret_names  = ["admin-password", "relay-auth-secret", "session-cookie-key", "store-encryption-key", "google-client-secret"]
  log_groups    = ["netbird-server", "dashboard", "traefik", "routing-peer"]

  # The local password sign-in (break-glass owner) is accepted only from the host itself (an SSM port-forward
  # arrives from the Docker gateway) and the VPN's own address.
  local_login_cidrs = ["172.30.0.1/32", "${aws_eip.vpn.public_ip}/32"]

  template_vars = {
    name               = var.name
    domain             = var.domain
    region             = data.aws_region.current.name
    images             = var.images
    letsencrypt_email  = var.letsencrypt_email
    admin_source_cidrs = var.admin_source_cidrs
    local_login_cidrs  = local.local_login_cidrs
  }

  # Every file the host needs, written by user data on first boot.
  host_files = {
    "/opt/vpn/docker-compose.yml"                = templatefile("${path.module}/templates/docker-compose.yml.tftpl", local.template_vars)
    "/opt/vpn/config.yaml.tmpl"                  = templatefile("${path.module}/templates/config.yaml.tftpl", local.template_vars)
    "/opt/vpn/dashboard.env"                     = templatefile("${path.module}/templates/dashboard.env.tftpl", local.template_vars)
    "/opt/vpn/traefik/dynamic.yaml"              = templatefile("${path.module}/templates/traefik-dynamic.yaml.tftpl", local.template_vars)
    "/opt/vpn/teams.json"                        = jsonencode(var.teams)
    "/opt/vpn/bin/vpn-configure"                 = file("${path.module}/files/vpn-configure")
    "/opt/vpn/bin/vpn-imds-guard"                = file("${path.module}/files/vpn-imds-guard")
    "/etc/systemd/system/vpn-imds-guard.service" = file("${path.module}/files/vpn-imds-guard.service")
    "/etc/systemd/system/vpn-imds-guard.timer"   = file("${path.module}/files/vpn-imds-guard.timer")
    "/etc/sysctl.d/90-vpn.conf"                  = "net.ipv4.ip_forward = 1\n"
    "/opt/vpn/vpn.env" = join("\n", [
      "VPN_NAME=${var.name}",
      "VPN_DOMAIN=${var.domain}",
      "VPN_EIP=${aws_eip.vpn.public_ip}",
      "VPN_REGION=${data.aws_region.current.name}",
      "VPN_SECRET_PREFIX=${local.secret_prefix}",
      "VPN_ADMIN_EMAIL=${var.admin_email}",
      "VPN_PEER_LOGIN_EXPIRATION_HOURS=${var.peer_login_expiration_hours}",
      "VPN_GOOGLE_CLIENT_ID=${var.google_client_id}",
      "VPN_COMPOSE_VERSION=${var.compose.version}",
      "VPN_COMPOSE_SHA256=${var.compose.sha256}",
      "",
    ])
  }

  user_data = join("\n", [
    templatefile("${path.module}/templates/user-data.sh.tftpl", { files = local.host_files }),
    file("${path.module}/files/bootstrap.sh"),
  ])
}

resource "aws_security_group" "vpn" {
  name        = "${var.name}-sg"
  description = "VPN: HTTPS, ACME, STUN and WireGuard in; egress to routed networks and the internet"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "public" {
  for_each = {
    https = { protocol = "tcp", port = 443, description = "Dashboard, API, gRPC, relay (Traefik)" }
    http  = { protocol = "tcp", port = 80, description = "HTTP to HTTPS redirect and Let's Encrypt" }
    stun  = { protocol = "udp", port = 3478, description = "STUN" }
    wg    = { protocol = "udp", port = 51820, description = "WireGuard to the routing peer (direct connections)" }
  }
  security_group_id = aws_security_group.vpn.id
  cidr_ipv4         = "0.0.0.0/0" # a VPN must be reachable from wherever people work
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  description       = each.value.description
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.vpn.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Routed team networks, package and image downloads, AWS APIs"
}

resource "aws_eip" "vpn" {
  domain = "vpc"
  tags   = { Name = var.name }
}

resource "aws_instance" "vpn" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.vpn.id]
  iam_instance_profile        = aws_iam_instance_profile.vpn.name
  associate_public_ip_address = false # the Elastic IP is its only address; bootstrap waits for it
  disable_api_termination     = true
  user_data_base64            = base64gzip(local.user_data)

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers can't reach the metadata service
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = false # NetBird's store lives here
  }

  tags = { Name = var.name, Backup = var.name }

  # First boot only: later changes to host files are applied on the host (README, Day 2), never by replacing it.
  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }

  depends_on = [aws_secretsmanager_secret.vpn, aws_cloudwatch_log_group.vpn]
}

resource "aws_eip_association" "vpn" {
  instance_id   = aws_instance.vpn.id
  allocation_id = aws_eip.vpn.id
}
