#!/bin/bash
set -e

# ======================================================
# CONFIGURATION
# ======================================================
# Uses the exported ZONE or defaults to europe-west4-a
ZONE=${ZONE:-"europe-west4-a"}
REGION="europe-west4"

VM="mc-server"
DISK="minecraft-disk"
IP_NAME="mc-server-ip"
# Using Project ID for bucket uniqueness as per Task 5
BUCKET_NAME="${DEVSHELL_PROJECT_ID}"

echo "Starting Minecraft Lab in ZONE: $ZONE"

# PRE-GENERATE SSH KEYS (Prevents the interactive prompt hang)
if [ ! -f ~/.ssh/google_compute_engine ]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/google_compute_engine
fi

# ======================================================
# TASK 1: CREATE VM & STATIC IP
# ======================================================
gcloud compute addresses create $IP_NAME \
  --region=$REGION --quiet || true

gcloud compute instances create $VM \
  --zone=$ZONE \
  --machine-type=e2-medium \
  --tags=minecraft-server \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --create-disk=name=$DISK,size=50GB,type=pd-ssd \
  --address=$IP_NAME \
  --scopes=storage-rw \
  --quiet

# ======================================================
# TASK 4: FIREWALL (Done early to ensure connectivity)
# ======================================================
gcloud compute firewall-rules create minecraft-rule \
  --allow=tcp:25565,tcp:22 \
  --target-tags=minecraft-server \
  --source-ranges=0.0.0.0/0 --quiet || true

echo "Waiting 30s for VM boot..."
sleep 30

# ======================================================
# TASK 2: PREPARE DATA DISK
# ======================================================
gcloud compute ssh $VM --zone=$ZONE --quiet --command="
sudo mkdir -p /home/minecraft && \
sudo mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/disk/by-id/google-$DISK && \
sudo mount -o discard,defaults /dev/disk/by-id/google-$DISK /home/minecraft
"

# ======================================================
# TASK 3: INSTALL & RUN APPLICATION
# ======================================================
gcloud compute ssh $VM --zone=$ZONE --quiet --command="
sudo apt-get update && \
sudo apt-get install -y default-jre-headless wget screen && \
cd /home/minecraft && \
sudo wget https://launcher.mojang.com/v1/objects/d0d0fe2b1dc6ab4c65554cb734270872b72dadd6/server.jar && \
sudo java -Xmx1024M -Xms1024M -jar server.jar nogui || true && \
echo 'eula=true' | sudo tee eula.txt && \
sudo screen -dmS mcs java -Xmx1024M -Xms1024M -jar server.jar nogui
"

# ======================================================
# TASK 5: SCHEDULE BACKUPS
# ======================================================
gcloud storage buckets create gs://${BUCKET_NAME}-minecraft-backup --location=$REGION --quiet || true

# Creating the backup script on the VM
gcloud compute ssh $VM --zone=$ZONE --quiet --command="
cat << 'EOF' | sudo tee /home/minecraft/backup.sh
#!/bin/bash
screen -r mcs -X stuff '/save-all\n/save-off\n'
/usr/bin/gcloud storage cp -R /home/minecraft/world gs://${BUCKET_NAME}-minecraft-backup/\$(date +%Y%m%d-%H%M%S)-world
screen -r mcs -X stuff '/save-on\n'
EOF
sudo chmod 755 /home/minecraft/backup.sh
# Run once to test
sudo /home/minecraft/backup.sh
# Setup Cron
(sudo crontab -l 2>/dev/null; echo '0 */4 * * * /home/minecraft/backup.sh') | sudo crontab -
"

echo "--------------------------------------------------"
echo "LAB COMPLETE"
echo "Minecraft IP: $(gcloud compute instances describe $VM --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
echo "--------------------------------------------------"
