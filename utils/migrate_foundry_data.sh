#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage:
  migrate_foundry_data.sh \
    --key /path/to/key.pem \
    --source-host OLD_SERVER_IP_OR_DNS \
    --dest-host NEW_SERVER_IP_OR_DNS \
    [--source-user ec2-user] \
    [--dest-user ec2-user] \
    [--source-path /foundrydata/Data] \
    [--dest-path /foundrydata/Data] \
    [--dry-run]

Description:
  Securely copy Foundry data from one server to another while preserving
  ownership, permissions, timestamps, ACLs, and xattrs.

  Run this script from your local machine. It uses your SSH key locally
  and does NOT require uploading the private key to either server.
EOF
}

require_arg() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "Missing required argument: ${name}" >&2
    print_usage >&2
    exit 1
  fi
}

SOURCE_USER="ec2-user"
DEST_USER="ec2-user"
SOURCE_PATH="/foundrydata/Data"
DEST_PATH="/foundrydata/Data"
KEY_PATH=""
SOURCE_HOST=""
DEST_HOST=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      KEY_PATH="${2:-}"
      shift 2
      ;;
    --source-host)
      SOURCE_HOST="${2:-}"
      shift 2
      ;;
    --dest-host)
      DEST_HOST="${2:-}"
      shift 2
      ;;
    --source-user)
      SOURCE_USER="${2:-}"
      shift 2
      ;;
    --dest-user)
      DEST_USER="${2:-}"
      shift 2
      ;;
    --source-path)
      SOURCE_PATH="${2:-}"
      shift 2
      ;;
    --dest-path)
      DEST_PATH="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift 1
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

require_arg "--key" "${KEY_PATH}"
require_arg "--source-host" "${SOURCE_HOST}"
require_arg "--dest-host" "${DEST_HOST}"

if [[ ! -f "${KEY_PATH}" ]]; then
  echo "Key file not found: ${KEY_PATH}" >&2
  exit 1
fi

if [[ ! -r "${KEY_PATH}" ]]; then
  echo "Key file is not readable: ${KEY_PATH}" >&2
  exit 1
fi

chmod 600 "${KEY_PATH}" || true

SSH_OPTS=(
  -i "${KEY_PATH}"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
)

SOURCE_TARGET="${SOURCE_USER}@${SOURCE_HOST}"
DEST_TARGET="${DEST_USER}@${DEST_HOST}"

echo "=== Foundry Data Migration ==="
echo "Source: ${SOURCE_TARGET}:${SOURCE_PATH}"
echo "Destination: ${DEST_TARGET}:${DEST_PATH}"
echo "Preserve: owner/group/perms/timestamps/ACLs/xattrs"
echo

echo "Checking SSH connectivity..."
ssh "${SSH_OPTS[@]}" "${SOURCE_TARGET}" "echo source-ok" >/dev/null
ssh "${SSH_OPTS[@]}" "${DEST_TARGET}" "echo dest-ok" >/dev/null

echo "Checking source and destination paths..."
ssh "${SSH_OPTS[@]}" "${SOURCE_TARGET}" "sudo test -d '${SOURCE_PATH}'"
ssh "${SSH_OPTS[@]}" "${DEST_TARGET}" "sudo mkdir -p '${DEST_PATH}'"

echo "Collecting source size estimate..."
ssh "${SSH_OPTS[@]}" "${SOURCE_TARGET}" "sudo du -sh '${SOURCE_PATH}' || true"
echo

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry-run mode enabled. No data copied."
  echo "Ready to run real copy with same arguments (without --dry-run)."
  exit 0
fi

echo "Stopping Foundry on destination to avoid file changes during extract..."
ssh "${SSH_OPTS[@]}" "${DEST_TARGET}" "sudo systemctl stop foundry || true"

echo "Streaming archive source -> destination..."
ssh "${SSH_OPTS[@]}" "${SOURCE_TARGET}" \
  "sudo tar --acls --xattrs --numeric-owner -cpf - -C '${SOURCE_PATH}' ." \
  | ssh "${SSH_OPTS[@]}" "${DEST_TARGET}" \
  "sudo tar --acls --xattrs --numeric-owner -xpf - -C '${DEST_PATH}'"

echo "Fixing destination folder permissions and restarting Foundry..."
ssh "${SSH_OPTS[@]}" "${DEST_TARGET}" \
  "if [[ -x /aws-foundry-ssl/utils/fix_folder_permissions.sh ]]; then sudo /aws-foundry-ssl/utils/fix_folder_permissions.sh; fi"
ssh "${SSH_OPTS[@]}" "${DEST_TARGET}" "sudo systemctl restart foundry || true"

echo "Migration complete."
