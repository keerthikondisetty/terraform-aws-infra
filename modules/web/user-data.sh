#!/usr/bin/env bash
#
# Instance bootstrap. Deliberately thin: pull the image and run it.
#
# Anything more than this belongs in the image, not in user data. User data
# runs once at first boot, is not re-run when it changes, and gives you no way
# to tell whether it succeeded short of reading the console log.

set -Eeuo pipefail

dnf install -y docker
systemctl enable --now docker

# The password is fetched at boot rather than baked into the template. User
# data is readable by anything that can reach the metadata service, so a
# credential in here is a credential in plain text.
DB_SECRET=$(aws secretsmanager get-secret-value \
    --secret-id "${db_secret}" \
    --query SecretString --output text)

docker run -d \
    --name app \
    --restart always \
    -p ${app_port}:8000 \
    -e DATABASE_URL="$(printf '%s' "$DB_SECRET" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')" \
    "${app_image}"
