#!/bin/bash
set -euo pipefail

# ------------------------------------------------------
# LetsEncrypt TLS (https) Certbot setup and auto-renewal
# ------------------------------------------------------

source /foundryssl/variables.sh

DOMAIN="${subdomain}.${fqdn}"
CERTBOT_BIN="/opt/certbot/bin/certbot"
PUBLIC_IP=""
RESOLVED_IP=""

echo "===== CERTBOT SETUP START ====="

if [[ "${enable_letsencrypt}" == "False" ]]; then
  echo "LetsEncrypt is disabled - check /foundryssl/variables.sh; exiting..."
  exit 0
fi

if [[ -z "${email:-}" ]]; then
  echo "Email address is not configured; exiting..."
  exit 1
fi

if [[ -z "${subdomain:-}" ]]; then
  echo "Subdomain is not configured; exiting..."
  exit 1
fi

if [[ -z "${fqdn:-}" ]]; then
  echo "Fully qualified domain name is not configured; exiting..."
  exit 1
fi

echo "Installing certbot dependencies..."
dnf install -y augeas-libs

if [[ ! -d /opt/certbot ]]; then
  python3 -m venv /opt/certbot/
fi

"${CERTBOT_BIN%/certbot}/pip" install --upgrade pip
"${CERTBOT_BIN%/certbot}/pip" install --upgrade certbot certbot-nginx

ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

echo "Installing renewal scripts and timers..."
mkdir -p /foundrycron

cp /aws-foundry-ssl/setup/certbot/certbot.sh /foundrycron/certbot.sh
chmod +x /foundrycron/certbot.sh

cp /aws-foundry-ssl/setup/certbot/certbot.service /etc/systemd/system/certbot.service
cp /aws-foundry-ssl/setup/certbot/certbot_start.timer /etc/systemd/system/certbot_start.timer
cp /aws-foundry-ssl/setup/certbot/certbot_renew.timer /etc/systemd/system/certbot_renew.timer

echo "Ensuring nginx helper include exists..."
cp /aws-foundry-ssl/setup/nginx/drop /etc/nginx/conf.d/drop

if ! grep -q "include conf.d/drop;" /etc/nginx/conf.d/foundryvtt.conf; then
  sed -i -e 's|location / {|include conf.d/drop;\n\n    location / {|g' /etc/nginx/conf.d/foundryvtt.conf
fi

echo "Configuring Foundry to expect SSL..."
sed -i 's/"proxyPort":.*/"proxyPort": "443",/g' /foundrydata/Config/options.json
sed -i 's/"proxySSL":.*/"proxySSL": true,/g' /foundrydata/Config/options.json

echo "Removing default nginx site to avoid conflicts..."
rm -f /etc/nginx/conf.d/default.conf

echo "Validating and restarting nginx..."
nginx -t
systemctl enable --now nginx
systemctl restart nginx

echo "Looking up instance public IP..."
PUBLIC_IP="$(curl -fsS http://169.254.169.254/latest/meta-data/public-ipv4 || true)"

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
      echo "Existing certificate found for ${DOMAIN}; checking renewal..."
      certbot renew --nginx --no-random-sleep-on-renew || true
    else
      echo "Requesting initial certificate for ${DOMAIN}..."
      certbot --nginx \
        --agree-tos \
        --non-interactive \
        --redirect \
        --no-eff-email \
        -m "${email}" \
        -d "${DOMAIN}" || true
    fi

    if [[ "${webserver_bool}" == "True" ]]; then
      echo "Requesting optional webserver certificate for ${fqdn} and www.${fqdn}..."
      certbot --nginx \
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

echo "Enabling certbot timers..."
systemctl daemon-reload
systemctl enable --now certbot_start.timer
systemctl enable --now certbot_renew.timer

echo "Final nginx validation..."
nginx -t
systemctl restart nginx

echo "===== CERTBOT SETUP COMPLETE ====="