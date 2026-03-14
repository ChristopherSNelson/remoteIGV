#!/usr/bin/env bash
set -euo pipefail

#
# Idempotent AWS setup for remoteIGV.
# Creates: S3 bucket, IAM role, security group, SSH key.
# Safe to re-run — skips resources that already exist.
#
# Usage: ./setup_aws.sh
#

REGION="us-east-2"
BUCKET="remoteigv-data"
KEY_NAME="remoteigv-key"
ROLE_NAME="remoteIGV-EC2-S3Read"
SG_NAME="remoteigv-sg"
PORT=8080

echo "========================================="
echo " remoteIGV — AWS Setup"
echo " Region: $REGION"
echo "========================================="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID"

# ---------- S3 Bucket ----------
echo ""
echo "[1/4] S3 bucket..."

if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  s3://$BUCKET exists"
else
  aws s3 mb "s3://$BUCKET" --region "$REGION"
  echo "  s3://$BUCKET created"
fi

# ---------- IAM Role ----------
echo ""
echo "[2/4] IAM role for EC2 → S3 read..."

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "  $ROLE_NAME exists"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Principal":{"Service":"ec2.amazonaws.com"},
        "Action":"sts:AssumeRole"
      }]
    }' > /dev/null
  echo "  Created $ROLE_NAME"
fi

# scope read access to just our bucket
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/remoteIGV-S3Read"
POLICY_DOC=$(cat <<POLICYJSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::${BUCKET}",
      "arn:aws:s3:::${BUCKET}/*"
    ]
  }]
}
POLICYJSON
)

if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
  echo "  Policy exists"
else
  aws iam create-policy --policy-name remoteIGV-S3Read \
    --policy-document "$POLICY_DOC" > /dev/null
  echo "  Created scoped S3 read policy"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true

# instance profile
if aws iam get-instance-profile --instance-profile-name remoteIGV-profile &>/dev/null; then
  echo "  Instance profile exists"
else
  aws iam create-instance-profile --instance-profile-name remoteIGV-profile > /dev/null
  aws iam add-role-to-instance-profile --instance-profile-name remoteIGV-profile --role-name "$ROLE_NAME"
  echo "  Created instance profile (waiting 10s for IAM propagation...)"
  sleep 10
fi

# ---------- Security Group ----------
echo ""
echo "[3/4] Security group..."

DEFAULT_VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION")

SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$DEFAULT_VPC" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "remoteIGV - web access from deployer IP" \
    --vpc-id "$DEFAULT_VPC" \
    --region "$REGION" \
    --query 'GroupId' --output text)
  echo "  Created SG: $SG_ID"
else
  echo "  SG exists: $SG_ID"
fi

MY_IP=$(curl -s https://checkip.amazonaws.com)/32
for P in 22 $PORT; do
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
    --protocol tcp --port "$P" --cidr "$MY_IP" 2>/dev/null || true
done
echo "  Ingress rules set for $MY_IP (ports 22, $PORT)"

# ---------- SSH Key ----------
echo ""
echo "[4/4] SSH key pair..."

KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
  echo "  Key pair $KEY_NAME exists"
  [ -f "$KEY_FILE" ] && echo "  Key file: $KEY_FILE" || echo "  WARNING: $KEY_FILE not found locally"
else
  mkdir -p "$HOME/.ssh"
  aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$REGION" \
    --query 'KeyMaterial' --output text > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "  Created $KEY_FILE"
fi

echo ""
echo "========================================="
echo " AWS setup complete!"
echo "========================================="
echo ""
echo "Resources:"
echo "  S3 bucket:    s3://$BUCKET"
echo "  IAM role:     $ROLE_NAME"
echo "  Sec group:    $SG_ID"
echo "  SSH key:      $KEY_FILE"
echo ""
echo "Next steps:"
echo "  1. Upload test data:  ./upload_test_data.sh"
echo "  2. Deploy server:     ./deploy.sh"
echo ""
