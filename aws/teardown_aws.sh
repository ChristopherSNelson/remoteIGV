#!/usr/bin/env bash
set -euo pipefail

#
# Tear down all remoteIGV AWS resources.
# Prompts before destructive actions.
#
# Usage: ./teardown_aws.sh [--yes]
#

REGION="us-east-2"
BUCKET="remoteigv-data"
KEY_NAME="remoteigv-key"
ROLE_NAME="remoteIGV-EC2-S3Read"
SG_NAME="remoteigv-sg"
TAG="remoteIGV"
AUTO_YES=false

[ "${1:-}" = "--yes" ] && AUTO_YES=true

confirm() {
  if $AUTO_YES; then return 0; fi
  read -rp "  $1 [y/N] " ans
  [[ "$ans" =~ ^[Yy] ]]
}

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "========================================="
echo " remoteIGV — AWS Teardown"
echo " Account: $ACCOUNT_ID  Region: $REGION"
echo "========================================="
echo ""

# ---------- EC2 Instance ----------
echo "[1/5] EC2 instance..."
INST=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$TAG" "Name=instance-state-name,Values=running,pending,stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null || echo "")

if [ -n "$INST" ] && [ "$INST" != "None" ]; then
  if confirm "Terminate instance $INST?"; then
    aws ec2 terminate-instances --instance-ids $INST --region "$REGION" > /dev/null
    echo "  Terminated $INST"
    echo "  Waiting for termination..."
    aws ec2 wait instance-terminated --instance-ids $INST --region "$REGION" 2>/dev/null || sleep 20
  fi
else
  echo "  No instance found"
fi

# ---------- Security Group ----------
echo ""
echo "[2/5] Security group..."
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
  if confirm "Delete security group $SG_ID ($SG_NAME)?"; then
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null \
      && echo "  Deleted" || echo "  Failed (may still be in use, retry later)"
  fi
else
  echo "  Not found"
fi

# ---------- SSH Key ----------
echo ""
echo "[3/5] SSH key pair..."
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
  if confirm "Delete key pair $KEY_NAME?"; then
    aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION"
    rm -f "$HOME/.ssh/${KEY_NAME}.pem"
    echo "  Deleted"
  fi
else
  echo "  Not found"
fi

# ---------- IAM ----------
echo ""
echo "[4/5] IAM role & policy..."
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/remoteIGV-S3Read"

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  if confirm "Delete IAM role $ROLE_NAME and its policy?"; then
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
    aws iam remove-role-from-instance-profile --instance-profile-name remoteIGV-profile --role-name "$ROLE_NAME" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name remoteIGV-profile 2>/dev/null || true
    aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
    aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
    echo "  Deleted role, profile, and policy"
  fi
else
  echo "  Not found"
fi

# ---------- S3 Bucket ----------
echo ""
echo "[5/5] S3 bucket..."
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  OBJ_COUNT=$(aws s3 ls "s3://$BUCKET" --recursive --region "$REGION" 2>/dev/null | wc -l | tr -d ' ')
  if confirm "Delete s3://$BUCKET ($OBJ_COUNT objects)?"; then
    aws s3 rb "s3://$BUCKET" --force --region "$REGION"
    echo "  Deleted"
  fi
else
  echo "  Not found"
fi

echo ""
echo "Teardown complete."
