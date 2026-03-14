#!/usr/bin/env bash
#
# Shared configuration for remoteIGV AWS scripts.
# Override any value with environment variables or a local .env file.
#
# Examples:
#   REMOTEIGV_REGION=eu-west-1 ./setup_aws.sh
#   echo 'REMOTEIGV_BUCKET=my-igv-bucket' > aws/.env && ./setup_aws.sh
#

# load .env if present (same directory as this file)
_config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_config_dir/.env" ] && source "$_config_dir/.env"

REGION="${REMOTEIGV_REGION:-us-east-2}"
BUCKET="${REMOTEIGV_BUCKET:-remoteigv-data}"
KEY_NAME="${REMOTEIGV_KEY_NAME:-remoteigv-key}"
ROLE_NAME="${REMOTEIGV_ROLE_NAME:-remoteIGV-EC2-S3Read}"
SG_NAME="${REMOTEIGV_SG_NAME:-remoteigv-sg}"
INSTANCE_TYPE="${REMOTEIGV_INSTANCE_TYPE:-t3.small}"
PORT="${REMOTEIGV_PORT:-8080}"
TAG="${REMOTEIGV_TAG:-remoteIGV}"

KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
