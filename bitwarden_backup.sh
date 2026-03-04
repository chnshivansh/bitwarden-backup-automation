#!/usr/bin/env bash

#stop script on command failure, ensures that traps work correctly, undefined variable reference and pipe failure will stop the script
set -Eeuo pipefail

#==============================
# ==============================
# CONFIG
# ==============================
SECRET_ID="prod/backup/bitwarden"
AWS_REGION="ap-south-1"

#setting up export path, temporary file system , stored directly into ram
EXPORT_PATH="/dev/shm/vault.json"

cleanup() {
    shred -u "$EXPORT_PATH" 2>/dev/null || true
    bw lock >/dev/null 2>&1 || true
    bw logout >/dev/null 2>&1 || true
}
trap cleanup EXIT


# ==============================
# Configure R2
# ==============================
export AWS_DEFAULT_REGION="auto"


#extracting secrets
echo "[*] Fetching secrets from AWS..."

SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text)

# ==============================
# Extract secrets
# ==============================
export BW_CLIENTID=$(echo "$SECRET_JSON" | jq -r .BW_CLIENTID)
export BW_CLIENTSECRET=$(echo "$SECRET_JSON" | jq -r .BW_CLIENTSECRET)
export BW_MASTERPASS=$(echo "$SECRET_JSON" | jq -r .BW_MASTERPASS)
export RESTIC_PASSWORD=$(echo "$SECRET_JSON" | jq -r .RESTIC_PASSWORD)
export AWS_ACCESS_KEY_ID=$(echo "$SECRET_JSON" | jq -r .R2_ACCESS_KEY_ID)
export AWS_SECRET_ACCESS_KEY=$(echo "$SECRET_JSON" | jq -r .R2_SECRET_ACCESS_KEY)
export R2_REPO=$(echo "$SECRET_JSON" | jq -r .R2_REPO)
export NTFY_SECRET=$(echo "$SECRET_JSON" | jq -r .NTFY_SECRET)

for var in BW_CLIENTID BW_CLIENTSECRET BW_MASTERPASS RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    [ -n "${!var}" ] || { echo "[!] Missing $var"; exit 1; }
done

#NTFY NOTIFICATION PIPELINE
START_TIME=$(date +%s)

notify_success() {
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    curl -fsS \
        -H "Title: Bitwarden Backup Success" \
        -H "Tags: white_check_mark,lock" \
        -d "Backup completed successfully. Duration: ${DURATION}s." \
        ntfy.sh/$NTFY_SECRET>/dev/null
}

notify_failure() {
    curl -fsS \
        -H "Title: Bitwarden Backup Failed" \
        -H "Priority: 5" \
        -H "Tags: warning,x" \
        -d "Backup failed on $(hostname)." \
        ntfy.sh/$NTFY_SECRET >/dev/null
}

trap notify_failure ERR

# ==============================
# Bitwarden Login
# ==============================
echo "[*] Logging into Bitwarden..."

bw logout >/dev/null 2>&1 || true
bw login --apikey --nointeraction

STATUS=$(bw status | jq -r .status)
if [ "$STATUS" != "locked" ]; then
    echo "[!] Login failed. Status: $STATUS"
    exit 1
fi

echo "[*] Unlocking vault..."

export BW_SESSION=$(bw unlock "$BW_MASTERPASS" --raw)
[ -n "$BW_SESSION" ] || { echo "[!] Unlock failed"; exit 1; }

# ==============================
# Export encrypted vault
# ==============================
echo "[*] Exporting encrypted vault..."

bw export \
    --format encrypted_json \
    --output "$EXPORT_PATH" \
    --session "$BW_SESSION"

[ -f "$EXPORT_PATH" ] || { echo "[!] Export failed"; exit 1; }

# ==============================
# Restic Backup
# ==============================
echo "[*] Running restic backup..."

restic -r "$R2_REPO" backup "$EXPORT_PATH" --tag bitwarden

echo "[*] Applying retention policy..."

restic -r "$R2_REPO" forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 12 \
    --keep-yearly 5 \
    --prune

echo "[✓] Backup completed successfully."
notify_success
