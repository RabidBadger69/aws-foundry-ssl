#!/bin/bash
set -euo pipefail

source /foundryssl/variables.sh

# NOTE:
# This script does not account for CloudFront (*.cloudfront.net).
# It updates Route53 A / AAAA records directly to the instance public IPs.

TTL=120
REMOVE_STALE_AAAA=true
EIP_LOOKUP_RETRIES=12
EIP_LOOKUP_DELAY_SEC=10

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required command not found: $1" >&2
        exit 1
    }
}

require_cmd aws
require_cmd jq
require_cmd curl
require_cmd ip

get_imdsv2_token() {
    curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

get_metadata() {
    local path="$1"
    local token="$2"
    curl -fsS -H "X-aws-ec2-metadata-token: ${token}" \
        "http://169.254.169.254/latest/meta-data/${path}"
}

get_dynamic_metadata() {
    local path="$1"
    local token="$2"
    curl -fsS -H "X-aws-ec2-metadata-token: ${token}" \
        "http://169.254.169.254/latest/dynamic/${path}"
}

has_global_ipv6() {
    ip -6 addr show scope global 2>/dev/null | grep -q "inet6"
}

get_instance_network_info() {
    local token="$1"

    INSTANCE_ID="$(get_metadata "instance-id" "${token}")"
    REGION="$(get_dynamic_metadata "instance-identity/document" "${token}" | jq -r '.region')"

    log "Instance ID: ${INSTANCE_ID}"
    log "Region: ${REGION}"
}

get_elastic_ipv4() {
    aws ec2 describe-addresses \
        --region "${REGION}" \
        --filters "Name=instance-id,Values=${INSTANCE_ID}" \
        --query 'Addresses[0].PublicIp' \
        --output text 2>/dev/null || true
}

is_usable_ip_value() {
    local value="$1"
    [[ -n "${value}" && "${value}" != "None" && "${value}" != "null" ]]
}

get_preferred_public_ipv4() {
    local eip=""
    local public_ipv4=""
    local attempt=1

    if [[ "${use_fixed_ip:-False}" == "True" ]]; then
        log "UseFixedIP=True; waiting for Elastic IP association..."

        while (( attempt <= EIP_LOOKUP_RETRIES )); do
            eip="$(get_elastic_ipv4)"

            if is_usable_ip_value "${eip}"; then
                log "Using Elastic IP: ${eip}"
                echo "${eip}"
                return 0
            fi

            log "Elastic IP not attached yet (attempt ${attempt}/${EIP_LOOKUP_RETRIES}); retrying in ${EIP_LOOKUP_DELAY_SEC}s"
            sleep "${EIP_LOOKUP_DELAY_SEC}"
            (( attempt++ ))
        done

        log "Elastic IP was not found after retries; falling back to instance public IPv4 lookup."
    fi

    eip="$(get_elastic_ipv4)"

    if is_usable_ip_value "${eip}"; then
        log "Using Elastic IP: ${eip}"
        echo "${eip}"
        return 0
    fi

    public_ipv4="$(get_metadata "public-ipv4" "${IMDS_TOKEN}" 2>/dev/null || true)"

    if [[ -n "${public_ipv4}" ]]; then
        log "Using instance public IPv4: ${public_ipv4}"
        echo "${public_ipv4}"
        return 0
    fi

    log "Could not determine any public IPv4 address"
    return 0
}

get_public_ipv6_from_metadata() {
    if ! has_global_ipv6; then
        return 0
    fi

    local mac
    mac="$(get_metadata "mac" "${IMDS_TOKEN}" 2>/dev/null || true)"

    if [[ -z "${mac}" ]]; then
        return 0
    fi

    local ipv6s
    ipv6s="$(get_metadata "network/interfaces/macs/${mac}/ipv6s" "${IMDS_TOKEN}" 2>/dev/null || true)"

    if [[ -n "${ipv6s}" ]]; then
        echo "${ipv6s}" | head -n1
    fi
}

list_recordsets() {
    aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}"
}

get_recordset_json() {
    local record_name="$1"
    local all_recordsets="$2"

    echo "${all_recordsets}" | jq ".ResourceRecordSets[] | select(.Name==\"${record_name}.\")"
}

get_record_value() {
    local record_type="$1"
    local recordset_blob="$2"

    echo "${recordset_blob}" | jq -r "select(.Type==\"${record_type}\") | .ResourceRecords[]?.Value" 2>/dev/null | head -n1 || true
}

upsert_recordset() {
    local record_name="$1"
    local record_type="$2"
    local record_value="$3"

    log "UPSERT ${record_type} ${record_name} -> ${record_value}"

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
                \"TTL\": ${TTL},
                \"ResourceRecords\": [
                  { \"Value\": \"${record_value}\" }
                ]
              }
            }
          ]
        }"
}

delete_recordset_if_present() {
    local record_name="$1"
    local record_type="$2"
    local record_value="$3"

    if [[ -z "${record_value}" ]]; then
        log "No existing ${record_type} record for ${record_name}; nothing to delete."
        return 0
    fi

    log "DELETE ${record_type} ${record_name} -> ${record_value}"

    aws route53 change-resource-record-sets \
        --hosted-zone-id "${zone_id}" \
        --change-batch "{
          \"Comment\": \"Remove stale DNS record\",
          \"Changes\": [
            {
              \"Action\": \"DELETE\",
              \"ResourceRecordSet\": {
                \"Name\": \"${record_name}.\",
                \"Type\": \"${record_type}\",
                \"TTL\": ${TTL},
                \"ResourceRecords\": [
                  { \"Value\": \"${record_value}\" }
                ]
              }
            }
          ]
        }" || true
}

sync_record() {
    local descriptor="$1"
    local record_name="$2"
    local desired_ip="$3"
    local record_type="$4"
    local recordset_blob="$5"

    local current_ip=""
    current_ip="$(get_record_value "${record_type}" "${recordset_blob}")"

    log "Checking ${descriptor} for ${record_name}"
    log "Desired ${descriptor}: ${desired_ip:-<none>}"
    log "Current ${descriptor}: ${current_ip:-<none>}"

    if [[ -n "${desired_ip}" ]]; then
        if [[ "${desired_ip}" != "${current_ip}" ]]; then
            upsert_recordset "${record_name}" "${record_type}" "${desired_ip}"
        else
            log "${descriptor} already matches; no change needed."
        fi
    else
        log "No desired ${descriptor} address available."

        if [[ "${record_type}" == "AAAA" && "${REMOVE_STALE_AAAA}" == "true" ]]; then
            delete_recordset_if_present "${record_name}" "${record_type}" "${current_ip}"
        else
            log "Skipping ${record_type} cleanup."
        fi
    fi

    log "-----"
}

main() {
    if [[ -z "${zone_id:-}" ]]; then
        echo "zone_id is not set in /foundryssl/variables.sh" >&2
        exit 1
    fi

    IMDS_TOKEN="$(get_imdsv2_token)"
    get_instance_network_info "${IMDS_TOKEN}"

    local ec2_ipv4=""
    local ec2_ipv6=""

    ec2_ipv4="$(get_preferred_public_ipv4 || true)"
    ec2_ipv6="$(get_public_ipv6_from_metadata || true)"

    if [[ -z "${ec2_ipv4}" ]]; then
        log "Warning: failed to determine public IPv4 address"
    fi

    if [[ -z "${ec2_ipv6}" ]]; then
        log "No public IPv6 address detected"
    else
        log "Using public IPv6: ${ec2_ipv6}"
    fi

    local all_recordsets=""
    all_recordsets="$(list_recordsets)"

    local subdomain_fqdn="${subdomain}.${fqdn}"
    local recordset_subdomain=""
    recordset_subdomain="$(get_recordset_json "${subdomain_fqdn}" "${all_recordsets}")"

    sync_record "IPv4" "${subdomain_fqdn}" "${ec2_ipv4}" "A" "${recordset_subdomain}"
    sync_record "IPv6" "${subdomain_fqdn}" "${ec2_ipv6}" "AAAA" "${recordset_subdomain}"

    if [[ "${webserver_bool}" == "True" ]]; then
        local recordset_root=""
        recordset_root="$(get_recordset_json "${fqdn}" "${all_recordsets}")"

        sync_record "IPv4" "${fqdn}" "${ec2_ipv4}" "A" "${recordset_root}"
        sync_record "IPv6" "${fqdn}" "${ec2_ipv6}" "AAAA" "${recordset_root}"
    fi

    log "--- All done!"
}

main "$@"
