# First boot (appended to templates/user-data.sh.tftpl). Runs once, as root. Log: /var/log/vpn-bootstrap.log.
# Secrets are never printed, never put on a command line, never written outside root-only files.
#
# Order matters:
#   1. netbird-server starts with its API on 127.0.0.1 only, and the owner account is created over localhost;
#   2. only then does Traefik open ports 80/443 and request the certificate. New certificates appear in Certificate
#      Transparency logs and scanners probe new names within minutes: an unclaimed setup endpoint must never be
#      reachable from the internet.
set -euo pipefail
umask 077
exec > >(tee -a /var/log/vpn-bootstrap.log) 2>&1
log() { echo "$(date -u +%FT%TZ) vpn: $*"; }
[[ -f /opt/vpn/.bootstrapped ]] && { log "already bootstrapped"; exit 0; }
cd /opt/vpn

# No public address of its own: wait for the Elastic IP. The IMDSv2 token reaches curl through a file descriptor.
imds() {
  local t
  t=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
  curl -fsS -H @<(printf 'X-aws-ec2-metadata-token: %s\n' "$t") "http://169.254.169.254/latest/meta-data/$1"
}
log "waiting for Elastic IP $VPN_EIP"
for _ in $(seq 1 90); do
  [[ "$(imds public-ipv4 2>/dev/null || true)" == "$VPN_EIP" ]] && break
  sleep 10
done
[[ "$(imds public-ipv4 2>/dev/null || true)" == "$VPN_EIP" ]] || { log "Elastic IP not attached after 15 minutes"; exit 1; }

log "packages"
dnf -y -q install docker jq nftables
# No SSH: administration is through Session Manager only (logged).
systemctl disable --now sshd.service sshd.socket 2>/dev/null || true
curl -fsSL --proto '=https' --tlsv1.2 --retry 5 -o /tmp/docker-compose \
  "https://github.com/docker/compose/releases/download/$VPN_COMPOSE_VERSION/docker-compose-linux-aarch64"
echo "$VPN_COMPOSE_SHA256  /tmp/docker-compose" | sha256sum -c -
install -D -m 0755 /tmp/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
rm -f /tmp/docker-compose
sysctl --system >/dev/null
systemctl enable --now docker

# Before any container or the routing peer starts: drop tunnel and container traffic to the metadata service.
systemctl daemon-reload
/opt/vpn/bin/vpn-imds-guard
systemctl enable --now vpn-imds-guard.timer

# The value of <prefix><name>; when it has none yet, generate it with $2 and store it. Values travel through pipes
# only (the AWS CLI reads --secret-string from stdin), never through argv.
export AWS_MAX_ATTEMPTS=3 AWS_RETRY_MODE=standard
sm() { aws --cli-connect-timeout 10 --cli-read-timeout 30 secretsmanager --region "$VPN_REGION" "$@"; }
secret() {
  local id="$VPN_SECRET_PREFIX$1" v
  if v=$(sm get-secret-value --secret-id "$id" --query SecretString --output text 2>/dev/null) && [[ -n "$v" ]]; then
    printf '%s' "$v"; return
  fi
  v=$(eval "$2")
  printf '%s' "$v" | sm put-secret-value --secret-id "$id" --secret-string file:///dev/stdin >/dev/null
  printf '%s' "$v"
}
sm describe-secret --secret-id "${VPN_SECRET_PREFIX}admin-password" --query Name --output text >/dev/null \
  || { log "cannot reach Secrets Manager (role, or an interface endpoint's security group)"; exit 1; }

log "secrets"
VPN_RELAY_AUTH_SECRET=$(secret relay-auth-secret 'openssl rand -base64 32 | tr -d "="')
VPN_SESSION_COOKIE_KEY=$(secret session-cookie-key 'openssl rand -base64 32')
VPN_STORE_ENCRYPTION_KEY=$(secret store-encryption-key 'openssl rand -base64 32')
VPN_ADMIN_PASSWORD=$(secret admin-password 'openssl rand -base64 30 | tr "+/" "-_"')
export VPN_RELAY_AUTH_SECRET VPN_SESSION_COOKIE_KEY VPN_STORE_ENCRYPTION_KEY
python3 - <<'PY'
import os
p = "/opt/vpn/config.yaml"
s = open(p + ".tmpl").read()
for k in ("RELAY_AUTH_SECRET", "SESSION_COOKIE_KEY", "STORE_ENCRYPTION_KEY"):
    s = s.replace(f"__{k}__", os.environ[f"VPN_{k}"])
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, s.encode()); os.close(fd)
PY
unset VPN_RELAY_AUTH_SECRET VPN_SESSION_COOKIE_KEY VPN_STORE_ENCRYPTION_KEY

log "netbird-server and dashboard (API on 127.0.0.1:8081 only)"
docker compose pull -q
docker compose up -d netbird-server dashboard
for _ in $(seq 1 60); do
  curl -fsS http://127.0.0.1:8081/api/instance >/tmp/instance.json 2>/dev/null && break
  sleep 5
done
jq -e 'has("setup_required")' /tmp/instance.json >/dev/null

VPN_PAT=""
if [[ "$(jq -r .setup_required /tmp/instance.json)" == "true" ]]; then
  log "creating owner $VPN_ADMIN_EMAIL over localhost"
  export VPN_ADMIN_PASSWORD
  SETUP=$(jq -n '{email: env.VPN_ADMIN_EMAIL, name: "vpn-owner", password: env.VPN_ADMIN_PASSWORD,
                  create_pat: true, pat_expire_in: 1}' \
          | curl -fsS -X POST http://127.0.0.1:8081/api/setup -H 'Content-Type: application/json' -d @-)
  VPN_PAT=$(jq -r '.personal_access_token // empty' <<<"$SETUP")
  OWNER_ID=$(jq -r .user_id <<<"$SETUP")
  [[ -n "$VPN_PAT" ]] || { log "setup returned no token"; exit 1; }
  log "owner created"
else
  log "setup already done: run /opt/vpn/bin/vpn-configure with an admin token"
fi
unset VPN_ADMIN_PASSWORD SETUP

log "waiting for $VPN_DOMAIN to resolve to $VPN_EIP before asking Let's Encrypt"
for _ in $(seq 1 240); do
  [[ "$(getent ahostsv4 "$VPN_DOMAIN" | awk 'NR==1{print $1}')" == "$VPN_EIP" ]] && break
  sleep 30
done
log "traefik (ports 80/443)"
docker compose up -d traefik
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null "https://$VPN_DOMAIN/api/instance" && break
  sleep 10
done

if [[ -n "$VPN_PAT" ]]; then
  export VPN_PAT
  # A failed configure must not leave the setup token behind.
  /opt/vpn/bin/vpn-configure || log "WARNING: vpn-configure failed: re-run it with an admin token (README, Day 2)"
  auth() { printf 'Authorization: Token %s\n' "$VPN_PAT"; }
  TOKEN_ID=$(curl -fsS -H @<(auth) "http://127.0.0.1:8081/api/users/$OWNER_ID/tokens" | jq -r '.[0].id // empty')
  [[ -n "$TOKEN_ID" ]] && curl -fsS -X DELETE -H @<(auth) \
    "http://127.0.0.1:8081/api/users/$OWNER_ID/tokens/$TOKEN_ID" >/dev/null
  unset VPN_PAT
  log "setup token deleted"
fi

touch /opt/vpn/.bootstrapped
log "done"
