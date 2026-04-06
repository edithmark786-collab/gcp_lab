#!/bin/bash
set -e

echo "Starting GCP Load Balancer Lab..."

# ======================================================
# ONLY CHANGE THESE (FROM LAB)
# ======================================================
REGION1=${REGION1:-"us-central1"}
REGION2=${REGION2:-"europe-west1"}

# ======================================================
# AUTO ZONES
# ======================================================
ZONE1=$(gcloud compute zones list --filter="region:$REGION1" --format="value(name)" | head -n 1)
ZONE2=$(gcloud compute zones list --filter="region:$REGION2" --format="value(name)" | head -n 1)

echo "Using: $REGION1 ($ZONE1) and $REGION2 ($ZONE2)"

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
# TASK 1: FIREWALL RULE
# ======================================================
echo "Creating firewall rule..."
gcloud compute firewall-rules create $FW_RULE \
  --network=$NETWORK \
  --allow=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-checks || true

# ======================================================
# TASK 2: CLOUD ROUTER + NAT
# ======================================================
echo "Creating Cloud Router..."
gcloud compute routers create $ROUTER \
  --network=$NETWORK \
  --region=$REGION1 || true

echo "Creating NAT gateway..."
gcloud compute routers nats create $NAT \
  --router=$ROUTER \
  --router-region=$REGION1 \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges || true

# ======================================================
# TASK 3: WEB SERVER VM + CUSTOM IMAGE
# ======================================================
echo "Creating webserver VM..."
gcloud compute instances create webserver \
  --zone=$ZONE1 \
  --machine-type=e2-micro \
  --tags=allow-health-checks \
  --no-address \
  --image-family=debian-11 \
  --image-project=debian-cloud \
  --boot-disk-auto-delete=no \
  --metadata=startup-script='#! /bin/bash
    apt-get update
    apt-get install -y apache2
    systemctl start apache2
    systemctl enable apache2'

echo "Waiting 120s for startup script to complete..."
sleep 120

echo "Deleting webserver VM (keeping boot disk)..."
gcloud compute instances delete webserver \
  --zone=$ZONE1 \
  --keep-disks=boot \
  --quiet

echo "Creating custom image from disk..."
gcloud compute images create $IMAGE \
  --source-disk=webserver \
  --source-disk-zone=$ZONE1

# ======================================================
# TASK 4: INSTANCE TEMPLATE + HEALTH CHECK + MIGs
# ======================================================
echo "Creating instance template..."
gcloud compute instance-templates create $TEMPLATE \
  --machine-type=e2-micro \
  --tags=allow-health-checks \
  --no-address \
  --image=$IMAGE \
  --network=$NETWORK

echo "Creating TCP health check..."
gcloud compute health-checks create tcp $HEALTH_CHECK --port=80

echo "Creating managed instance group in $REGION1..."
gcloud compute instance-groups managed create $MIG1 \
  --region=$REGION1 \
  --template=$TEMPLATE \
  --size=1

echo "Creating managed instance group in $REGION2..."
gcloud compute instance-groups managed create $MIG2 \
  --region=$REGION2 \
  --template=$TEMPLATE \
  --size=1

echo "Setting autoscaling for $MIG1..."
gcloud compute instance-groups managed set-autoscaling $MIG1 \
  --region=$REGION1 \
  --max-num-replicas=2 \
  --min-num-replicas=1 \
  --target-load-balancing-utilization=0.8 \
  --cool-down-period=60

echo "Setting autoscaling for $MIG2..."
gcloud compute instance-groups managed set-autoscaling $MIG2 \
  --region=$REGION2 \
  --max-num-replicas=2 \
  --min-num-replicas=1 \
  --target-load-balancing-utilization=0.8 \
  --cool-down-period=60

echo "Setting autohealing for $MIG1..."
gcloud beta compute instance-groups managed update $MIG1 \
  --region=$REGION1 \
  --health-check=$HEALTH_CHECK \
  --initial-delay=60

echo "Setting autohealing for $MIG2..."
gcloud beta compute instance-groups managed update $MIG2 \
  --region=$REGION2 \
  --health-check=$HEALTH_CHECK \
  --initial-delay=60

# ======================================================
# TASK 5: APPLICATION LOAD BALANCER
# ======================================================
echo "Creating backend service..."
gcloud compute backend-services create $BACKEND \
  --protocol=HTTP \
  --health-checks=$HEALTH_CHECK \
  --global \
  --enable-logging \
  --logging-sample-rate=1.0

echo "Adding $MIG1 backend (RATE mode)..."
gcloud compute backend-services add-backend $BACKEND \
  --instance-group=$MIG1 \
  --instance-group-region=$REGION1 \
  --balancing-mode=RATE \
  --max-rate-per-instance=50 \
  --capacity-scaler=1.0 \
  --global

echo "Adding $MIG2 backend (UTILIZATION mode)..."
gcloud compute backend-services add-backend $BACKEND \
  --instance-group=$MIG2 \
  --instance-group-region=$REGION2 \
  --balancing-mode=UTILIZATION \
  --max-utilization=0.8 \
  --capacity-scaler=1.0 \
  --global

echo "Creating URL map..."
gcloud compute url-maps create $URL_MAP \
  --default-service=$BACKEND

echo "Creating HTTP proxy..."
gcloud compute target-http-proxies create $PROXY \
  --url-map=$URL_MAP

echo "Creating IPv4 forwarding rule..."
gcloud compute forwarding-rules create $FWD_RULE \
  --target-http-proxy=$PROXY \
  --ports=80 \
  --global

echo "Creating IPv6 forwarding rule..."
gcloud compute forwarding-rules create ${FWD_RULE}-ipv6 \
  --target-http-proxy=$PROXY \
  --ports=80 \
  --ip-version=IPV6 \
  --global

# ======================================================
# WAIT FOR LOAD BALANCER TO BE READY
# ======================================================
LB_IP=$(gcloud compute forwarding-rules describe $FWD_RULE \
  --global --format="value(IPAddress)")

echo "Load Balancer IPv4: $LB_IP"
echo "Waiting for Load Balancer to become ready..."

while true; do
  RESULT=$(curl -m2 -s http://$LB_IP || true)
  if [[ "$RESULT" == *"Apache"* ]]; then
    echo "Load Balancer is ready!"
    break
  fi
  echo "Still waiting..."
  sleep 10
done

# ======================================================
# TASK 6: STRESS TEST VM
# ======================================================
echo "Creating stress-test VM..."
gcloud compute instances create stress-test \
  --zone=$ZONE1 \
  --machine-type=e2-micro \
  --image=$IMAGE \
  --no-address \
  --tags=allow-health-checks

echo "Waiting 60s for stress-test VM to be ready..."
sleep 60

echo "Generating SSH keys if needed..."
gcloud compute config-ssh --quiet

echo "Running stress test..."
gcloud compute ssh stress-test \
  --zone=$ZONE1 \
  --quiet \
  --command="ab -n 500000 -c 1000 http://$LB_IP/"

echo ""
echo "=============================="
echo " LAB COMPLETED SUCCESSFULLY"
echo " LB IPv4: $LB_IP"
echo "=============================="
