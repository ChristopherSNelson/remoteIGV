#!/usr/bin/env bash
set -euo pipefail

#
# Deploy remoteIGV to EC2. Mounts S3 bucket via mountpoint-s3.
# Prerequisite: run setup_aws.sh first.
#
# Usage:
#   ./deploy.sh            # launch instance and start server
#   ./deploy.sh --stop     # stop (but keep) the instance
#   ./deploy.sh --start    # restart a stopped instance
#

REGION="us-east-2"
BUCKET="remoteigv-data"
INSTANCE_TYPE="t3.small"
KEY_NAME="remoteigv-key"
TAG="remoteIGV"
PORT=8080
ACTION="deploy"

while [[ $# -gt 0 ]]; do
  case $1 in
    --stop)  ACTION="stop"; shift ;;
    --start) ACTION="start"; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

# ── helper: find running instance ──────────────────────────────
find_instance() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$TAG" "Name=instance-state-name,Values=$1" \
    --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null || echo ""
}

get_ip() {
  aws ec2 describe-instances --instance-ids "$1" --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

# ── stop ───────────────────────────────────────────────────────
if [ "$ACTION" = "stop" ]; then
  INST=$(find_instance "running")
  if [ -n "$INST" ] && [ "$INST" != "None" ]; then
    aws ec2 stop-instances --instance-ids $INST --region "$REGION" > /dev/null
    echo "Stopped $INST (use --start to resume, costs $0 while stopped except EBS)"
  else
    echo "No running instance found"
  fi
  exit 0
fi

# ── start existing stopped instance ────────────────────────────
if [ "$ACTION" = "start" ]; then
  INST=$(find_instance "stopped")
  if [ -n "$INST" ] && [ "$INST" != "None" ]; then
    aws ec2 start-instances --instance-ids $INST --region "$REGION" > /dev/null
    aws ec2 wait instance-running --instance-ids $INST --region "$REGION"
    IP=$(get_ip "$INST")
    echo "Restarted $INST → http://${IP}:${PORT}"
  else
    echo "No stopped instance found"
  fi
  exit 0
fi

# ── deploy ─────────────────────────────────────────────────────
echo "========================================="
echo " remoteIGV — Deploy to EC2"
echo "========================================="

# check prereqs
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
  echo "ERROR: Run setup_aws.sh first." >&2; exit 1
fi

SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=remoteigv-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$SG_ID" = "None" ]; then
  echo "ERROR: Security group not found. Run setup_aws.sh first." >&2; exit 1
fi

# reuse existing?
EXISTING=$(find_instance "running,pending")
if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  INSTANCE_ID="$EXISTING"
  echo "Using existing instance: $INSTANCE_ID"
else
  echo ""
  echo "Launching t3.small..."

  AMI=$(aws ec2 describe-images --region "$REGION" \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

  USERDATA=$(cat <<STARTUP
#!/bin/bash
set -ex
dnf install -y python3.11 python3.11-pip fuse
curl -Lo /tmp/mount-s3.rpm https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.rpm
dnf install -y /tmp/mount-s3.rpm
mkdir -p /mnt/s3data
mount-s3 ${BUCKET} /mnt/s3data --allow-other --read-only
mkdir -p /opt/remoteigv/static
python3.11 -m pip install fastapi uvicorn python-multipart jinja2 aiofiles
touch /opt/remoteigv/.ready
STARTUP
)

  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile Name=remoteIGV-profile \
    --user-data "$USERDATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG}]" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
    --query 'Instances[0].InstanceId' --output text)
  echo "Launched: $INSTANCE_ID"
fi

# wait for it
echo "Waiting for instance..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
PUBLIC_IP=$(get_ip "$INSTANCE_ID")
echo "IP: $PUBLIC_IP"

echo "Waiting for SSH..."
for i in $(seq 1 30); do
  ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
    ec2-user@"$PUBLIC_IP" "echo ok" &>/dev/null && break
  sleep 5
done

# copy app
echo "Deploying app files..."
scp -i "$KEY_FILE" -o StrictHostKeyChecking=no -q \
  "$APP_DIR/server.py" ec2-user@"$PUBLIC_IP":/tmp/
scp -i "$KEY_FILE" -o StrictHostKeyChecking=no -q -r \
  "$APP_DIR/templates" ec2-user@"$PUBLIC_IP":/tmp/

ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ec2-user@"$PUBLIC_IP" << REMOTE
  sudo cp /tmp/server.py /opt/remoteigv/
  sudo cp -r /tmp/templates /opt/remoteigv/

  # wait for user-data to finish
  for i in \$(seq 1 60); do [ -f /opt/remoteigv/.ready ] && break; sleep 5; done

  # wait for S3 mount
  for i in \$(seq 1 30); do mountpoint -q /mnt/s3data && break; sleep 3; done

  # kill old server if running
  sudo pkill -f 'server.py' 2>/dev/null || true
  sleep 1

  # start
  sudo nohup python3.11 /opt/remoteigv/server.py \
    --data-dir /mnt/s3data --port $PORT \
    > /var/log/remoteigv.log 2>&1 &
  sleep 2
  echo "PID: \$(pgrep -f 'server.py' || echo 'starting...')"
REMOTE

echo ""
echo "========================================="
echo " remoteIGV is live!"
echo "========================================="
echo ""
echo "  URL:   http://${PUBLIC_IP}:${PORT}"
echo ""
echo "  SSH:   ssh -i $KEY_FILE ec2-user@${PUBLIC_IP}"
echo "  Logs:  ssh ... 'tail -f /var/log/remoteigv.log'"
echo "  Stop:  ./deploy.sh --stop   (saves ~\$0.02/hr)"
echo "  Start: ./deploy.sh --start"
echo ""
