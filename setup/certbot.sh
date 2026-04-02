#!/bin/bash
set -euo pipefail

# ------------------------------------------------------
# LetsEncrypt TLS (https) Certbot setup and auto-renewal
# ------------------------------------------------------

source /foundryssl/variables.sh

DOMAIN="${subdomain}.${fqdn}"
PUBLIC_IP=""
RESOLVED_IP=""
CERTBOT_ENV_FLAGS=""

echo "===== CERTBOT SETUP START ====="

if [[ "${enable_letsencrypt:-False}" != "True" ]]; then
  echo "LetsEncrypt is disabled - exiting..."
  exit 0
fi

if [[ -z "${email:-}" || -z "${subdomain:-}" || -z "${fqdn:-}" ]]; then
  echo "Missing one or more required variables: email, subdomain, fqdn"
  exit 1
fi

if [[ "${enable_letsencrypt_staging:-False}" == "True" ]]; then
  CERTBOT_ENV_FLAGS="--staging"
  echo "LetsEncrypt staging mode enabled for testing."
fi

echo "Installing certbot dependencies..."
dnf install -y augeas-libs python3 python3-pip

if [[ ! -d /opt/certbot ]]; then
  python3 -m venv /opt/certbot
fi

/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install --upgrade certbot certbot-nginx

ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

echo "Installing renewal scripts and timers..."
mkdir -p /foundrycron

[[ -f /aws-foundry-ssl/setup/certbot/certbot.sh ]] && cp /aws-foundry-ssl/setup/certbot/certbot.sh /foundrycron/certbot.sh
[[ -f /foundrycron/certbot.sh ]] && chmod +x /foundrycron/certbot.sh
[[ -f /aws-foundry-ssl/setup/certbot/certbot.service ]] && cp /aws-foundry-ssl/setup/certbot/certbot.service /etc/systemd/system/certbot.service
[[ -f /aws-foundry-ssl/setup/certbot/certbot_start.timer ]] && cp /aws-foundry-ssl/setup/certbot/certbot_start.timer /etc/systemd/system/certbot_start.timer
[[ -f /aws-foundry-ssl/setup/certbot/certbot_renew.timer ]] && cp /aws-foundry-ssl/setup/certbot/certbot_renew.timer /etc/systemd/system/certbot_renew.timer

echo "Ensuring nginx helper include exists..."
if [[ -f /aws-foundry-ssl/setup/nginx/drop ]]; then
  cp /aws-foundry-ssl/setup/nginx/drop /etc/nginx/conf.d/drop
fi

if [[ -f /etc/nginx/conf.d/foundryvtt.conf ]]; then
  if ! grep -q "include conf.d/drop;" /etc/nginx/conf.d/foundryvtt.conf; then
    sed -i -e 's|location / {|include conf.d/drop;\n\n    location / {|g' /etc/nginx/conf.d/foundryvtt.conf
  fi
fi

echo "Removing default nginx site to avoid conflicts..."
rm -f /etc/nginx/conf.d/default.conf

echo "Validating and restarting nginx..."
nginx -t || true
systemctl enable --now nginx || true
systemctl restart nginx || true

echo "Looking up instance public IP via IMDSv2..."
TOKEN="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"

if [[ -n "${TOKEN}" ]]; then
  PUBLIC_IP="$(curl -fsS \
    -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
else
  PUBLIC_IP=""
fi

if [[ -z "${PUBLIC_IP}" ]]; then
  echo "Could not determine public IPv4 from instance metadata."
  echo "Skipping immediate certificate request; renewal timers are still installed."
else
  echo "Waiting for DNS: ${DOMAIN} -> ${PUBLIC_IP}"

  for i in {1..30}; do
    RESOLVED_IP="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1; exit}' || true)"

    if [[ "${RESOLVED_IP}" == "${PUBLIC_IP}" ]]; then
      echo "DNS is ready: ${DOMAIN} resolves to ${RESOLVED_IP}"
      break
    fi

    echo "Attempt ${i}/30: ${DOMAIN} currently resolves to '${RESOLVED_IP:-<nothing>}'"
    sleep 10
  done

  if [[ "${RESOLVED_IP}" == "${PUBLIC_IP}" ]]; then
    if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
      echo "Existing certificate found for ${DOMAIN}; attempting renewal..."
      certbot renew --nginx --no-random-sleep-on-renew ${CERTBOT_ENV_FLAGS} || true
    else
      echo "Requesting initial certificate for ${DOMAIN}..."
      certbot --nginx \
        ${CERTBOT_ENV_FLAGS} \
        --agree-tos \
        --non-interactive \
        --redirect \
        --no-eff-email \
        -m "${email}" \
        -d "${DOMAIN}" || true
    fi

    if [[ "${webserver_bool:-False}" == "True" ]]; then
      echo "Requesting optional webserver certificate for ${fqdn} and www.${fqdn}..."
      certbot --nginx \
        ${CERTBOT_ENV_FLAGS} \
        --agree-tos \
        --non-interactive \
        --redirect \
        --no-eff-email \
        -m "${email}" \
        -d "${fqdn}" \
        -d "www.${fqdn}" || true
    fi
  else
    echo "DNS did not resolve to this instance in time."
    echo "Skipping immediate certificate issuance; renewal/start timers remain installed."
  fi
fi

echo "Configuring Foundry to expect SSL if certificate now exists..."
if [[ -f /foundrydata/Config/options.json && -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
  sed -i 's/"proxyPort":.*/"proxyPort": "443",/g' /foundrydata/Config/options.json

  if grep -q '"proxySSL":' /foundrydata/Config/options.json; then
    sed -i 's/"proxySSL":.*/"proxySSL": true,/g' /foundrydata/Config/options.json
  fi
fi

echo "Enabling certbot timers..."
systemctl daemon-reload

[[ -f /etc/systemd/system/certbot_start.timer ]] && systemctl enable --now certbot_start.timer || true
[[ -f /etc/systemd/system/certbot_renew.timer ]] && systemctl enable --now certbot_renew.timer || true

echo "Final nginx validation..."
nginx -t || true
systemctl restart nginx || true

echo "===== CERTBOT SETUP COMPLETE ====="
