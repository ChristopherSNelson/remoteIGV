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
#   ./deploy.sh --redeploy # update code on running instance
#
#   REMOTEIGV_REGION=eu-west-1 ./deploy.sh   # override region
#

source "$(dirname "$0")/config.sh"

ACTION="deploy"
while [[ $# -gt 0 ]]; do
  case $1 in
    --stop)     ACTION="stop"; shift ;;
    --start)    ACTION="start"; shift ;;
    --redeploy) ACTION="redeploy"; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

# ── helpers ──────────────────────────────────────────────────────
find_instance() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$TAG" "Name=instance-state-name,Values=$1" \
    --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null || echo ""
}

get_ip() {
  aws ec2 describe-instances --instance-ids "$1" --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

wait_for_ssh() {
  local ip=$1
  echo "Waiting for SSH..."
  for i in $(seq 1 30); do
    if ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
      ec2-user@"$ip" "echo ok" &>/dev/null; then
      return 0
    fi
    sleep 5
  done
  echo "ERROR: SSH not available after 150s." >&2
  return 1
}

deploy_files() {
  local ip=$1
  echo "Deploying app files..."

  if [ ! -f "$APP_DIR/server.py" ]; then
    echo "ERROR: server.py not found in $APP_DIR" >&2
    return 1
  fi

  scp -i "$KEY_FILE" -o StrictHostKeyChecking=no -q \
    "$APP_DIR/server.py" ec2-user@"$ip":/tmp/
  scp -i "$KEY_FILE" -o StrictHostKeyChecking=no -q -r \
    "$APP_DIR/templates" ec2-user@"$ip":/tmp/

  ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ec2-user@"$ip" << REMOTE
    set -e

    # wait for user-data to finish (cloud-init installs packages)
    echo "Waiting for cloud-init..."
    for i in \$(seq 1 120); do
      [ -f /opt/remoteigv/.ready ] && break
      sleep 5
    done
    if [ ! -f /opt/remoteigv/.ready ]; then
      echo "ERROR: cloud-init did not finish. Check /var/log/cloud-init-output.log" >&2
      exit 1
    fi

    # wait for S3 mount
    echo "Waiting for S3 mount..."
    for i in \$(seq 1 30); do
      mountpoint -q /mnt/s3data && break
      sleep 3
    done
    if ! mountpoint -q /mnt/s3data; then
      echo "ERROR: S3 not mounted at /mnt/s3data" >&2
      exit 1
    fi

    # copy app files
    sudo cp /tmp/server.py /opt/remoteigv/
    sudo cp -r /tmp/templates /opt/remoteigv/

    # install systemd service
    sudo tee /etc/systemd/system/remoteigv.service > /dev/null << 'SVC'
[Unit]
Description=remoteIGV server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/remoteigv
ExecStart=/usr/bin/python3.11 /opt/remoteigv/server.py --data-dir /mnt/s3data --port $PORT
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/remoteigv.log
StandardError=append:/var/log/remoteigv.log

[Install]
WantedBy=multi-user.target
SVC

    sudo systemctl daemon-reload
    sudo systemctl enable remoteigv
    sudo systemctl restart remoteigv

    # verify it started
    sleep 2
    if sudo systemctl is-active --quiet remoteigv; then
      echo "Server running (systemd)"
    else
      echo "ERROR: Server failed to start. Logs:" >&2
      sudo journalctl -u remoteigv --no-pager -n 20 >&2
      exit 1
    fi
REMOTE
}

# ── stop ───────────────────────────────────────────────────────
if [ "$ACTION" = "stop" ]; then
  INST=$(find_instance "running")
  if [ -n "$INST" ] && [ "$INST" != "None" ]; then
    aws ec2 stop-instances --instance-ids $INST --region "$REGION" > /dev/null
    echo "Stopped $INST (use --start to resume, costs \$0 while stopped except EBS)"
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

# ── redeploy to running instance ───────────────────────────────
if [ "$ACTION" = "redeploy" ]; then
  INST=$(find_instance "running")
  if [ -z "$INST" ] || [ "$INST" = "None" ]; then
    echo "No running instance found. Use ./deploy.sh to launch one." >&2
    exit 1
  fi
  IP=$(get_ip "$INST")
  echo "Redeploying to $INST ($IP)..."
  deploy_files "$IP"
  echo ""
  echo "Updated: http://${IP}:${PORT}"
  exit 0
fi

# ── deploy ─────────────────────────────────────────────────────
echo "========================================="
echo " remoteIGV — Deploy to EC2"
echo "========================================="

# check prereqs
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
  echo "ERROR: Key pair '$KEY_NAME' not found. Run setup_aws.sh first." >&2
  exit 1
fi

if [ ! -f "$KEY_FILE" ]; then
  echo "ERROR: SSH key not found at $KEY_FILE" >&2
  exit 1
fi

SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  echo "ERROR: Security group '$SG_NAME' not found. Run setup_aws.sh first." >&2
  exit 1
fi

# reuse existing?
EXISTING=$(find_instance "running,pending")
if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  INSTANCE_ID="$EXISTING"
  echo "Using existing instance: $INSTANCE_ID"
else
  echo ""
  echo "Launching $INSTANCE_TYPE..."

  AMI=$(aws ec2 describe-images --region "$REGION" \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

  if [ -z "$AMI" ] || [ "$AMI" = "None" ]; then
    echo "ERROR: Could not find Amazon Linux 2023 AMI in $REGION." >&2
    exit 1
  fi

  USERDATA=$(cat <<STARTUP
#!/bin/bash
set -ex
dnf install -y python3.11 python3.11-pip fuse
curl -Lo /tmp/mount-s3.rpm https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.rpm
dnf install -y /tmp/mount-s3.rpm
mkdir -p /mnt/s3data
mount-s3 ${BUCKET} /mnt/s3data --allow-other --read-only
mkdir -p /opt/remoteigv/static /opt/remoteigv/templates
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

if ! wait_for_ssh "$PUBLIC_IP"; then
  exit 1
fi

deploy_files "$PUBLIC_IP"

echo ""
echo "========================================="
echo " remoteIGV is live!"
echo "========================================="
echo ""
echo "  URL:   http://${PUBLIC_IP}:${PORT}"
echo ""
echo "  SSH:   ssh -i $KEY_FILE ec2-user@${PUBLIC_IP}"
echo "  Logs:  ssh ... 'sudo journalctl -u remoteigv -f'"
echo "  Stop:  ./deploy.sh --stop   (saves ~\$0.02/hr)"
echo "  Start: ./deploy.sh --start"
echo "  Update code: ./deploy.sh --redeploy"
echo ""
