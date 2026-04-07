#!/bin/bash
set -e

echo "🚀 Starting GCP Load Balancer Lab (Final Fixed Version)"

# ======================================================
# INPUTS (LAB VALUES)
# ======================================================
REGION1=${REGION1:-"us-west1"}
REGION2=${REGION2:-"asia-east1"}
ZONE1=${ZONE1:-"us-west1-a"}

echo "Using REGION1=$REGION1 REGION2=$REGION2 ZONE1=$ZONE1"

# ======================================================
# VARIABLES
# ======================================================
NETWORK="default"
FW_RULE="fw-allow-health-checks"
ROUTER="nat-router-us1"
NAT="nat-config"

IMAGE="mywebserver"
TEMPLATE="mywebserver-template"
HEALTH_CHECK="http-health-check"

MIG1="us-1-mig"
MIG2="notus-1-mig"

BACKEND="http-backend"
URL_MAP="http-lb"
PROXY="http-lb-proxy"
FWD_RULE="http-lb-forwarding-rule"

# ======================================================
# FIREWALL
# ======================================================
gcloud compute firewall-rules create $FW_RULE \
  --network=$NETWORK \
  --allow=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-checks || true

# ======================================================
# NAT
# ======================================================
gcloud compute routers create $ROUTER \
  --network=$NETWORK \
  --region=$REGION1 || true

gcloud compute routers nats create $NAT \
  --router=$ROUTER \
  --router-region=$REGION1 \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges || true

# ======================================================
# WEB SERVER IMAGE
# ======================================================
gcloud compute instances create webserver \
  --zone=$ZONE1 \
  --machine-type=e2-micro \
  --tags=allow-health-checks \
  --no-address \
  --image-family=debian-11 \
  --image-project=debian-cloud \
  --metadata=startup-script='#! /bin/bash
apt-get update
apt-get install -y apache2
systemctl start apache2
systemctl enable apache2'

sleep 90

gcloud compute instances delete webserver \
  --zone=$ZONE1 \
  --keep-disks=boot \
  --quiet

gcloud compute images create $IMAGE \
  --source-disk=webserver \
  --source-disk-zone=$ZONE1 || true

# ======================================================
# TEMPLATE + HEALTH CHECK
# ======================================================
gcloud compute instance-templates create $TEMPLATE \
  --machine-type=e2-micro \
  --tags=allow-health-checks \
  --no-address \
  --image=$IMAGE \
  --network=$NETWORK || true

gcloud compute health-checks create tcp $HEALTH_CHECK --port=80 || true

# ======================================================
# MIG
# ======================================================
gcloud compute instance-groups managed create $MIG1 \
  --region=$REGION1 \
  --template=$TEMPLATE \
  --size=1 || true

gcloud compute instance-groups managed create $MIG2 \
  --region=$REGION2 \
  --template=$TEMPLATE \
  --size=1 || true

# ✅ IMPORTANT FIX (Task 5 key)
gcloud compute instance-groups managed set-named-ports $MIG1 \
  --region=$REGION1 \
  --named-ports=http:80

gcloud compute instance-groups managed set-named-ports $MIG2 \
  --region=$REGION2 \
  --named-ports=http:80

# Autoscaling
gcloud compute instance-groups managed set-autoscaling $MIG1 \
  --region=$REGION1 \
  --max-num-replicas=2 \
  --target-load-balancing-utilization=0.8

gcloud compute instance-groups managed set-autoscaling $MIG2 \
  --region=$REGION2 \
  --max-num-replicas=2 \
  --target-load-balancing-utilization=0.8

# Autohealing
gcloud beta compute instance-groups managed set-autohealing $MIG1 \
  --region=$REGION1 \
  --health-check=$HEALTH_CHECK \
  --initial-delay=60

gcloud beta compute instance-groups managed set-autohealing $MIG2 \
  --region=$REGION2 \
  --health-check=$HEALTH_CHECK \
  --initial-delay=60

# ======================================================
# LOAD BALANCER
# ======================================================
gcloud compute backend-services create $BACKEND \
  --protocol=HTTP \
  --health-checks=$HEALTH_CHECK \
  --global || true

# Disable IAP (important)
gcloud compute backend-services update $BACKEND \
  --global \
  --no-enable-iap || true

# Add backends
gcloud compute backend-services add-backend $BACKEND \
  --instance-group=$MIG1 \
  --instance-group-region=$REGION1 \
  --global || true

gcloud compute backend-services add-backend $BACKEND \
  --instance-group=$MIG2 \
  --instance-group-region=$REGION2 \
  --global || true

# URL map
gcloud compute url-maps create $URL_MAP \
  --default-service=$BACKEND || true

# CLEAN OLD LB (critical fix)
gcloud compute forwarding-rules delete $FWD_RULE --global --quiet || true
gcloud compute forwarding-rules delete ${FWD_RULE}-ipv6 --global --quiet || true
gcloud compute target-http-proxies delete $PROXY --global --quiet || true

# Create proxy
gcloud compute target-http-proxies create $PROXY \
  --url-map=$URL_MAP

# IPv4 rule
gcloud compute forwarding-rules create $FWD_RULE \
  --load-balancing-scheme=EXTERNAL \
  --network-tier=PREMIUM \
  --global \
  --target-http-proxy=$PROXY \
  --ports=80

# IPv6 rule (Task 5 requirement)
gcloud compute forwarding-rules create ${FWD_RULE}-ipv6 \
  --load-balancing-scheme=EXTERNAL \
  --network-tier=PREMIUM \
  --global \
  --target-http-proxy=$PROXY \
  --ports=80 \
  --ip-version=IPV6

# ======================================================
# WAIT FOR LB
# ======================================================
LB_IP=$(gcloud compute forwarding-rules describe $FWD_RULE \
  --global --format="value(IPAddress)")

echo "🌐 Load Balancer IP: $LB_IP"
echo "⏳ Waiting for LB to respond..."

while true; do
  RESULT=$(curl -m2 -s http://$LB_IP || true)
  if [[ "$RESULT" == *"Apache"* ]]; then
    break
  fi
  sleep 5
done

# ======================================================
# STRESS TEST
# ======================================================
gcloud compute instances create stress-test \
  --zone=$ZONE1 \
  --machine-type=e2-micro \
  --image-family=debian-11 \
  --image-project=debian-cloud \
  --metadata=startup-script='#! /bin/bash
apt-get update
apt-get install -y apache2-utils' || true

sleep 60

gcloud compute ssh stress-test \
  --zone=$ZONE1 \
  --quiet \
  --command="ab -n 500000 -c 1000 http://$LB_IP/"

echo "🎉 LAB COMPLETED SUCCESSFULLY"
