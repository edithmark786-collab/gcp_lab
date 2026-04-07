```bash
#!/bin/bash
set -e

echo "Starting GCP Load Balancer Lab..."

# ======================================================
# INPUT FROM LAB
# ======================================================
REGION1=${REGION1:-"us-west1"}
REGION2=${REGION2:-"asia-southeast1"}
ZONE1=${ZONE1:-"us-west1-a"}

echo "Using REGION1=$REGION1 REGION2=$REGION2 ZONE1=$ZONE1"

# ======================================================
# VARIABLES
# ======================================================
NETWORK="default"
IMAGE="mywebserver"
TEMPLATE="mywebserver-template"
HEALTH_CHECK="http-health-check"

MIG1="us-1-mig"
MIG2="notus-1-mig"

# ======================================================
# WEB SERVER + IMAGE
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
  --source-disk-zone=$ZONE1

# ======================================================
# TEMPLATE + HEALTH CHECK
# ======================================================
gcloud compute instance-templates create $TEMPLATE \
  --machine-type=e2-micro \
  --tags=allow-health-checks \
  --no-address \
  --image=$IMAGE \
  --network=$NETWORK

gcloud compute health-checks create tcp $HEALTH_CHECK --port=80

# ======================================================
# MIG
# ======================================================
gcloud compute instance-groups managed create $MIG1 \
  --region=$REGION1 \
  --template=$TEMPLATE \
  --size=1

gcloud compute instance-groups managed create $MIG2 \
  --region=$REGION2 \
  --template=$TEMPLATE \
  --size=1

# ✅ IMPORTANT: Named ports (FIXES PORT ISSUE)
gcloud compute instance-groups managed set-named-ports $MIG1 \
  --region=$REGION1 \
  --named-ports=http:80

gcloud compute instance-groups managed set-named-ports $MIG2 \
  --region=$REGION2 \
  --named-ports=http:80

# ======================================================
# LOAD BALANCER
# ======================================================

# Backend service (FIXED)
gcloud compute backend-services create http-backend \
  --protocol=HTTP \
  --port-name=http \
  --health-checks=$HEALTH_CHECK \
  --global \
  --enable-logging \
  --logging-sample-rate=1.0

# us-1-mig → RATE 50
gcloud compute backend-services add-backend http-backend \
  --instance-group=$MIG1 \
  --instance-group-region=$REGION1 \
  --balancing-mode=RATE \
  --max-rate-per-instance=50 \
  --capacity-scaler=1.0 \
  --global

# notus-1-mig → UTILIZATION 80
gcloud compute backend-services add-backend http-backend \
  --instance-group=$MIG2 \
  --instance-group-region=$REGION2 \
  --balancing-mode=UTILIZATION \
  --max-utilization=0.8 \
  --capacity-scaler=1.0 \
  --global

# URL MAP + PROXY
gcloud compute url-maps create http-lb \
  --default-service=http-backend

gcloud compute target-http-proxies create http-lb-proxy \
  --url-map=http-lb

# ======================================================
# FRONTEND (FIXED EXACTLY)
# ======================================================

# IPv4 (Ephemeral)
gcloud compute forwarding-rules create http-lb-forwarding-rule \
  --target-http-proxy=http-lb-proxy \
  --ports=80 \
  --global

# IPv6 (Auto-allocate)
gcloud compute forwarding-rules create http-lb-ipv6 \
  --target-http-proxy=http-lb-proxy \
  --ports=80 \
  --ip-version=IPV6 \
  --global

echo "=================================="
echo "TASK 5 FULLY FIXED"
echo "=================================="
```
