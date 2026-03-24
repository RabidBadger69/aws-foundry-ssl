#!/bin/bash
set -euo pipefail

# -----------------------
# Install and configure nginx
# -----------------------

source /foundryssl/variables.sh

echo "===== NGINX SETUP START ====="

if [[ "${webserver_bool:-False}" == "True" ]]; then
  foundry_file="foundryvtt_webserver.conf"
else
  foundry_file="foundryvtt.conf"
fi

echo "Using nginx config template: ${foundry_file}"

# Install nginx from the nginx mainline repo
cp /aws-foundry-ssl/setup/nginx/nginx.repo /etc/yum.repos.d/nginx.repo
dnf config-manager --enable nginx-mainline
dnf install -y nginx --repo nginx-mainline

# Prepare logging directory
mkdir -p /var/log/nginx/foundry

# Remove default site so nginx does not serve the welcome page
rm -f /etc/nginx/conf.d/default.conf

# Install Foundry vhost
cp "/aws-foundry-ssl/setup/nginx/${foundry_file}" /etc/nginx/conf.d/foundryvtt.conf

# Replace template placeholders
sed -i "s/YOURSUBDOMAINHERE/${subdomain}/g" /etc/nginx/conf.d/foundryvtt.conf
sed -i "s/YOURDOMAINHERE/${fqdn}/g" /etc/nginx/conf.d/foundryvtt.conf

# Install helper include used by the Foundry/certbot flow
if [[ -f /aws-foundry-ssl/setup/nginx/drop ]]; then
  cp /aws-foundry-ssl/setup/nginx/drop /etc/nginx/conf.d/drop
  chmod 644 /etc/nginx/conf.d/drop
fi

# Ensure correct permissions for nginx config files
chmod 644 /etc/nginx/conf.d/foundryvtt.conf

# Configure Foundry to run behind nginx on HTTP first.
# certbot.sh can later switch proxyPort/proxySSL to 443/true.
if [[ -f /foundrydata/Config/options.json ]]; then
  sed -i "s/\"hostname\":.*/\"hostname\": \"${subdomain}.${fqdn}\",/g" /foundrydata/Config/options.json
  sed -i 's/"proxyPort":.*/"proxyPort": "80",/g' /foundrydata/Config/options.json

  if grep -q '"proxySSL":' /foundrydata/Config/options.json; then
    sed -i 's/"proxySSL":.*/"proxySSL": false,/g' /foundrydata/Config/options.json
  fi
else
  echo "WARNING: /foundrydata/Config/options.json not found yet; skipping Foundry proxy config update"
fi

# Optional static website setup
if [[ "${webserver_bool:-False}" == "True" ]]; then
  echo "Setting up optional webserver content..."
  git clone https://github.com/zkkng/foundry-website.git /foundry-website
  cp -rf /foundry-website/* /usr/share/nginx/html
  chown -R ec2-user:ec2-user /usr/share/nginx/html
  chmod -R 755 /usr/share/nginx/html
  rm -rf /foundry-website
fi

# Validate nginx config before enabling/restarting
echo "Validating nginx configuration..."
nginx -t

echo "Enabling and restarting nginx..."
systemctl enable nginx
systemctl restart nginx

echo "===== NGINX SETUP COMPLETE ====="