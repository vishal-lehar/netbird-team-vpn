variable "region" {
  description = "AWS region of the VPN host."
  type        = string
}

variable "name" {
  description = "Name prefix for every resource (instance, roles, secrets, log groups)."
  type        = string
  default     = "team-vpn"
}

variable "domain" {
  description = "Public DNS name of the VPN, e.g. vpn.example.com. Point an A record at the Elastic IP (output elastic_ip), not proxied."
  type        = string
}

variable "admin_email" {
  description = "Email of the break-glass owner account, created on first boot over localhost. Its password is generated into Secrets Manager."
  type        = string
}

variable "letsencrypt_email" {
  description = "Contact email for the Let's Encrypt certificate."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the VPN host."
  type        = string
}

variable "subnet_id" {
  description = "A public subnet (route to an internet gateway) in vpc_id. The host gets an Elastic IP, no auto-assigned public address."
  type        = string
}

variable "instance_type" {
  description = "Graviton instance type. t4g.small is enough for a few dozen users; t4g.medium for a few hundred."
  type        = string
  default     = "t4g.small"
}

variable "teams" {
  description = <<-EOT
    Who reaches what over the VPN. One NetBird group per team (team-<key>); admins put people in groups in the
    dashboard. Each team gets routes to its networks and may use only its ports there. A network shared by several
    teams gets one route; each team's policy still allows only its own ports.
  EOT
  type = map(object({
    description = string
    networks    = list(string) # private CIDRs this team reaches through the VPN
    ports       = list(string) # TCP ports allowed to those networks
  }))
}

variable "peer_login_expiration_hours" {
  description = "Every device re-authenticates (sign-in + MFA) at least this often."
  type        = number
  default     = 24
}

variable "admin_source_cidrs" {
  description = "If set, only these source CIDRs reach the dashboard and the management API. VPN clients don't need either (they use gRPC, relay and /oauth2)."
  type        = list(string)
  default     = []
}

variable "google_client_id" {
  description = "Optional: a Google OAuth client (consent screen Internal) for 'Sign in with Google'. Put its secret in <name>-google-client-secret. Empty: local accounts only."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Optional: email subscribed to the VPN's alarm topic."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention."
  type        = number
  default     = 90
}

variable "images" {
  description = "Container images pinned by digest (all multi-arch, arm64 included). Read the release notes before changing."
  type = object({
    server    = string
    dashboard = string
    client    = string
    traefik   = string
  })
  default = {
    server    = "netbirdio/netbird-server:0.80.0@sha256:05b3d8d6d056e5062a2965d4d6e5d6d83f09f2bf9133947a8e5972e0e0e7a261"
    dashboard = "netbirdio/dashboard:v2.94.0@sha256:70e0fc6dd3b7758148d182fb55ecd8d4f9ce01e9bba56c9389224e0b8354009d"
    client    = "netbirdio/netbird:0.80.0@sha256:4976692ea44bb93871743d0b742b4a8f97f6425bfc458ca2d78e28fdb8bdf4ad"
    traefik   = "traefik:v3.6@sha256:31267173a15b4944e797a76ffd9c419707c8d8b32fe5b610f80cd0cfa05f372d"
  }
}

variable "compose" {
  description = "Docker Compose plugin for Amazon Linux 2023 (not packaged): version and sha256 of docker-compose-linux-aarch64."
  type        = object({ version = string, sha256 = string })
  default = {
    version = "v5.6.0"
    sha256  = "733ec76717ceb59052a9609b9dadfb523b2df8eab57a54212872d10a58078ea2"
  }
}

variable "tags" {
  description = "Extra tags for every resource."
  type        = map(string)
  default     = {}
}
