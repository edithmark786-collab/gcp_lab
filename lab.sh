```bash
#!/bin/bash
set -e

echo "Starting GCP Load Balancer Lab..."

# ======================================================
# REGION (AUTO OR OVERRIDE)
# ======================================================

REGION1=${REGION1:-$(gcloud compute project-info describe --format="value(defaultComputeRegion)" 2>/dev/null)}
REGION1=${REGION1:-"us-central1"}

REGION2=${REGION2:-$(gcloud compute regions list --format="value(name)" | grep -v "$REGION1" | head -n 1)}

ZONE1=$(gcloud compute zones list --filter="region:$REGION1 AND status=UP" --format="value(name)" | head -n 1)
ZONE2=$(gcloud compute zones list --filter="region:$REGION2 AND status=UP" --format="value(name)" | head -n 1)

PROJECT_ID=$(gcloud config get-value project)

echo "--------------------------------"
echo "Project : $PROJECT_ID"
echo "Region1 : $REGION1 ($ZONE1)"
echo "Region2 : $REGION2 ($ZONE2)"
echo "--------------------------------"

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
echo "Creating firewall rule..."
gcloud compute firewall-rules create $FW_RULE \
  --network=$NETWORK \
  --allow=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-checks || true

# ======================================================
# NAT
# ======================================================
echo "Creating NAT..."
gcloud compute routers create $ROUTER \
  --network=$NETWORK \
  --region=$REGION1 || true

gcloud compute routers nats create $NAT \
  --router=$ROUTER \
  --router-region=$REGION1 \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges || true

# ======================================================
# WEB SERVER
# ======================================================
echo "Creating webserver VM..."
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

echo "Waiting for VM setup..."
sleep 90

echo "Deleting VM but keeping disk..."
gcloud compute instances delete webserver \
  --zone=$ZONE1 \
  --keep-disks=boot \
  --quiet

echo "Creating custom image..."
gcloud compute images create $IMAGE \
  --source-disk=webserver \
  --source-disk-zone=$ZONE1

# ======================================================
# TEMPLATE + HEALTH CHECK
# ======================================================
echo "Creating instance template..."
gcloud compute instance-templates create $TEMPLATE \
  --machine-type=e2-micro \
  --tags=allow-health-checks \
  --no-address \
  --image=$IMAGE \
  --network=$NETWORK

echo "Creating health check..."
gcloud compute health-checks create tcp $HEALTH_CHECK --port=80

# ======================================================
# MIG
# ======================================================
echo "Creating managed instance groups..."
gcloud compute instance-groups managed create $MIG1 \
  --region=$REGION1 \
  --template=$TEMPLATE \
  --size=1

gcloud compute instance-groups managed create $MIG2 \
  --region=$REGION2 \
  --template=$TEMPLATE \
  --size=1

echo "Setting autoscaling..."
gcloud compute instance-groups managed set-autoscaling $MIG1 \
  --region=$REGION1 \
  --max-num-replicas=2 \
  --target-load-balancing-utilization=0.8

gcloud compute instance-groups managed set-autoscaling $MIG2 \
  --region=$REGION2 \
  --max-num-replicas=2 \
  --target-load-balancing-utilization=0.8

echo "Setting autohealing..."
gcloud compute instance-groups managed set-autohealing $MIG1 \
  --region=$REGION1 \
  --health-check=$HEALTH_CHECK \
  --initial-delay=60

gcloud compute instance-groups managed set-autohealing $MIG2 \
  --region=$REGION2 \
  --health-check=$HEALTH_CHECK \
  --initial-delay=60

# ======================================================
# LOAD BALANCER
# ======================================================
echo "Creating load balancer..."

gcloud compute backend-services create $BACKEND \
  --protocol=HTTP \
  --health-checks=$HEALTH_CHECK \
  --global \
  --enable-logging \
  --logging-sample-rate=1.0

gcloud compute backend-services add-backend $BACKEND \
  --instance-group=$MIG1 \
  --instance-group-region=$REGION1 \
  --balancing-mode=RATE \
  --max-rate-per-instance=50 \
  --global

gcloud compute backend-services add-backend $BACKEND \
  --instance-group=$MIG2 \
  --instance-group-region=$REGION2 \
  --balancing-mode=UTILIZATION \
  --max-utilization=0.8 \
  --global

gcloud compute url-maps create $URL_MAP \
  --default-service=$BACKEND

gcloud compute target-http-proxies create $PROXY \
  --url-map=$URL_MAP

gcloud compute forwarding-rules create $FWD_RULE \
  --target-http-proxy=$PROXY \
  --ports=80 \
  --global

gcloud compute forwarding-rules create ${FWD_RULE}-ipv6 \
  --target-http-proxy=$PROXY \
  --ports=80 \
  --ip-version=IPV6 \
  --global

echo "Load balancer created successfully"

# ======================================================
# DONE
# ======================================================
echo "Lab setup completed successfully"
```
