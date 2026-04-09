#!/bin/bash
set -e

echo "Starting Minecraft Lab..."

# ======================================================
# INPUT
# ======================================================
ZONE=${ZONE:-"europe-west4-a"}
REGION="europe-west4"

VM="mc-server"
DISK="minecraft-disk"
IP_NAME="mc-server-ip"
BUCKET="${DEVSHELL_PROJECT_ID}-minecraft-backup"

echo "Using ZONE=$ZONE"

# PRE-GENERATE SSH KEYS (Prevents the prompt that killed your last run)
if [ ! -f ~/.ssh/google_compute_engine ]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/google_compute_engine
fi

# ======================================================
# STATIC IP
# ======================================================
gcloud compute addresses create $IP_NAME \
  --region=$REGION --quiet || true

# ======================================================
# VM + DISK
# ======================================================
gcloud compute instances create $VM \
  --zone=$ZONE \
  --machine-type=e2-medium \
  --tags=minecraft-server \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --create-disk=name=$DISK,size=50GB,type=pd-ssd \
  --address=$IP_NAME \
  --quiet

# ======================================================
# FIREWALL
# ======================================================
# Opening 25565 for Minecraft AND 22 for SSH access
gcloud compute firewall-rules create minecraft-rule \
  --allow=tcp:25565,tcp:22 \
  --target-tags=minecraft-server \
  --source-ranges=0.0.0.0/0 --quiet || true

echo "Waiting 30 seconds for VM to initialize..."
sleep 30

# ======================================================
# SERVER SETUP
# ======================================================
gcloud compute ssh $VM --zone=$ZONE --quiet --command="
sudo mkdir -p /home/minecraft && \
sudo mkfs.ext4 -F /dev/disk/by-id/google-$DISK && \
sudo mount /dev/disk/by-id/google-$DISK /home/minecraft && \
cd /home/minecraft && \
sudo apt-get update && \
sudo apt-get install -y default-jre-headless wget screen && \
sudo wget https://piston-data.mojang.com/v1/objects/8410fd3a199345ef749179853920613271780f2d/server.jar && \
sudo java -Xmx1024M -Xms1024M -jar server.jar nogui || true
"

# ACCEPT EULA
gcloud compute ssh $VM --zone=$ZONE --quiet --command="
cd /home/minecraft && echo 'eula=true' | sudo tee eula.txt
"

# START SERVER
gcloud compute ssh $VM --zone=$ZONE --quiet --command="
cd /home/minecraft && \
sudo screen -dmS mcs java -Xmx1024M -Xms1024M -jar server.jar nogui
"

# ======================================================
# BACKUP SETUP
# ======================================================
gcloud storage buckets create gs://$BUCKET --location=$REGION --quiet || true

gcloud compute ssh $VM --zone=$ZONE --quiet --command="
cat << 'EOF' | sudo tee /home/minecraft/backup.sh
#!/bin/bash
screen -r mcs -X stuff '/save-all\n/save-off\n'
/usr/bin/gcloud storage cp -R /home/minecraft/world gs://$BUCKET/\$(date +%Y%m%d-%H%M%S)-world
screen -r mcs -X stuff '/save-on\n'
EOF
sudo chmod +x /home/minecraft/backup.sh
"

# CRON
gcloud compute ssh $VM --zone=$ZONE --quiet --command="
(sudo crontab -l 2>/dev/null; echo '0 */4 * * * /home/minecraft/backup.sh') | sudo crontab -
"

echo "===================================="
echo "LAB COMPLETED (Task 1–5)"
echo "Public IP Address:"
gcloud compute instances describe $VM --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
echo "===================================="
