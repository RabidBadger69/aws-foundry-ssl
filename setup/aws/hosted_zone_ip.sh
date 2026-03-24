#!/bin/bash
source /foundryssl/variables.sh

# NOTE:
# This script does not account for CloudFront (*.cloudfront.net).
# It updates Route53 A / AAAA records directly to the instance public IPs.

updateRecordset() {
    # $1 - Descriptor for logging - "IPv4" or "IPv6"
    # $2 - Record name eg. "play.example.com"
    # $3 - EC2 IP
    # $4 - Record type - "A" or "AAAA"
    # $5 - RecordSet JSON blob from Route53

    local descriptor="$1"
    local record_name="$2"
    local ec2_ip="$3"
    local record_type="$4"
    local recordset_blob="$5"
    local recordset_ip=""

    if [[ -z "${ec2_ip}" ]]; then
        echo "No local ${descriptor} address set; skipping..."
        echo "-----"
        return 0
    fi

    recordset_ip="$(echo "${recordset_blob}" | jq -r "select(.Type==\"${record_type}\") | .ResourceRecords[]?.Value" 2>/dev/null | head -n1 || true)"

    echo "EC2 ${descriptor} Address: ${ec2_ip}"
    echo "RRS ${descriptor} Address: ${recordset_ip}"

    if [[ "${ec2_ip}" != "${recordset_ip}" ]]; then
        echo "Requesting change for ${record_name} ${descriptor} to ${ec2_ip}"
        aws route53 change-resource-record-sets \
            --hosted-zone-id "${zone_id}" \
            --change-batch "{
              \"Comment\": \"Dynamic DNS change\",
              \"Changes\": [
                {
                  \"Action\": \"UPSERT\",
                  \"ResourceRecordSet\": {
                    \"Name\": \"${record_name}.\",
                    \"Type\": \"${record_type}\",
                    \"TTL\": 120,
                    \"ResourceRecords\": [
                      { \"Value\": \"${ec2_ip}\" }
                    ]
                  }
                }
              ]
            }"
    else
        echo "${descriptor} matches, no change needed."
    fi

    echo "-----"
}

has_global_ipv6() {
    ip -6 addr show scope global 2>/dev/null | grep -q "inet6" || return 1
}

get_public_ipv4() {
    dig -4 +short txt ch whoami.cloudflare @1.0.0.1 2>/dev/null | tr -d '"' | head -n1 || true
}

get_public_ipv6() {
    if ! has_global_ipv6; then
        return 0
    fi

    dig -6 +short txt ch whoami.cloudflare @2606:4700:4700::1001 2>/dev/null | tr -d '"' | head -n1 || true
}

# Attempt to retrieve public IPv4 and IPv6 with retry logic
max_retries=5
retry_delay=10
ec2_ipv4=""
ec2_ipv6=""

for ((attempt=1; attempt<=max_retries; attempt++)); do
    echo "Querying public IP addresses (attempt ${attempt}/${max_retries})..."

    if [[ -z "${ec2_ipv4}" ]]; then
        ec2_ipv4_raw="$(get_public_ipv4)"
        if [[ "${ec2_ipv4_raw}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ec2_ipv4="${ec2_ipv4_raw}"
            echo "IPv4 retrieved: ${ec2_ipv4}"
        fi
    fi

    if [[ -z "${ec2_ipv6}" ]]; then
        ec2_ipv6_raw="$(get_public_ipv6)"
        if [[ "${ec2_ipv6_raw}" =~ : ]]; then
            ec2_ipv6="${ec2_ipv6_raw}"
            echo "IPv6 retrieved: ${ec2_ipv6}"
        else
            if has_global_ipv6; then
                echo "IPv6 lookup did not return a valid address on this attempt."
            else
                echo "No global IPv6 address present; skipping IPv6 lookup."
            fi
        fi
    fi

    # Proceed as soon as we have IPv4.
    # IPv6 is optional and should never block the install.
    if [[ -n "${ec2_ipv4}" ]]; then
        break
    fi

    if (( attempt < max_retries )); then
        echo "No IPv4 retrieved yet, retrying in ${retry_delay}s..."
        sleep "${retry_delay}"
    fi
done

if [[ -z "${ec2_ipv4}" ]]; then
    echo "Warning: Failed to retrieve valid IPv4 address after ${max_retries} attempts"
fi

if [[ -z "${ec2_ipv6}" ]]; then
    echo "Warning: Failed to retrieve valid IPv6 address after ${max_retries} attempts"
fi

# Get Route53 record sets
recordset_subdomain="$(aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" | jq ".ResourceRecordSets[] | select(.Name==\"${subdomain}.${fqdn}.\")")"

# --- Subdomain checks ---
updateRecordset "IPv4" "${subdomain}.${fqdn}" "${ec2_ipv4}" "A" "${recordset_subdomain}"
updateRecordset "IPv6" "${subdomain}.${fqdn}" "${ec2_ipv6}" "AAAA" "${recordset_subdomain}"

# --- Optional domain checks ---
if [[ "${webserver_bool}" == "True" ]]; then
    recordset_fqdn="$(aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" | jq ".ResourceRecordSets[] | select(.Name==\"${fqdn}.\")")"

    updateRecordset "IPv4" "${fqdn}" "${ec2_ipv4}" "A" "${recordset_fqdn}"
    updateRecordset "IPv6" "${fqdn}" "${ec2_ipv6}" "AAAA" "${recordset_fqdn}"
fi

echo "--- All done!"