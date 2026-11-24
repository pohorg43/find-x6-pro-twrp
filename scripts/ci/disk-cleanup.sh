#!/usr/bin/env bash
set -euo pipefail

echo "=== Native CI Disk Cleanup and Memory Optimization ==="

echo "--- 1. Block devices layout (lsblk) ---"
lsblk || true

echo "--- 2. Disk space before cleanup ---"
df -h

echo "--- 3. Stopping docker/containerd/snap services and removing pre-existing swap ---"
sudo systemctl stop docker.service docker.socket containerd.service containerd snapd 2>/dev/null || true
if [ -f /swapfile ]; then
    echo "Disabling and removing pre-existing /swapfile on /..."
    sudo swapoff /swapfile 2>/dev/null || true
    sudo rm -f /swapfile 2>/dev/null || true
fi
if [ -f /mnt/swapfile ]; then
    echo "Disabling and removing pre-existing /mnt/swapfile..."
    sudo swapoff /mnt/swapfile 2>/dev/null || true
    sudo rm -f /mnt/swapfile 2>/dev/null || true
fi

echo "--- 4. Aggressive cleanup of preinstalled runtimes and SDKs ---"
sudo rm -rf \
    /usr/share/dotnet \
    /usr/local/lib/android \
    /opt/ghc \
    /opt/hostedtoolcache \
    /usr/local/share/boost \
    /usr/share/swift \
    /usr/lib/jvm \
    /usr/local/lib/node_modules \
    /usr/local/share/chromium \
    /usr/local/share/powershell \
    /usr/local/graalvm \
    /usr/local/.ghcup \
    /usr/local/aws-cli \
    /usr/local/aws-sam-cli \
    /usr/lib/google-cloud-sdk \
    /opt/az \
    /opt/microsoft \
    /usr/share/doc \
    /usr/share/man \
    /var/lib/snapd \
    /snap \
    /var/lib/docker \
    /var/lib/containerd \
    /etc/docker \
    /var/run/docker.sock \
    /var/cache/apt/archives/* \
    /var/lib/apt/lists/* || true

sudo apt-get clean 2>/dev/null || true

echo "--- 5. Configuring 12G Disk Swap (kexi1412 OOM prevention recipe) ---"
if mountpoint -q /mnt; then
    echo "Found dedicated mountpoint at /mnt. Placing swapfile on /mnt..."
    SWAP_FILE="/mnt/swapfile"
else
    echo "No separate mountpoint on /mnt. Placing swapfile on /..."
    SWAP_FILE="/swapfile"
fi

echo "Creating 12G disk swapfile at $SWAP_FILE..."
sudo fallocate -l 12G "$SWAP_FILE" || sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count=12288
sudo chmod 600 "$SWAP_FILE"
sudo mkswap "$SWAP_FILE"
sudo swapon "$SWAP_FILE"

echo "--- 6. Memory & Swap status ---"
free -h
swapon --show || true

echo "--- 7. Disk space on / after cleanup ---"
df -h /

echo "--- 8. Top 15 storage consumers in /usr, /opt, /var ---"
sudo du -xh --max-depth=2 /usr /opt /var 2>/dev/null | sort -hr | head -n 15 || true

ROOT_FREE=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
echo "=== Available space on /: ${ROOT_FREE}G ==="
if [ "$ROOT_FREE" -lt 45 ]; then
    echo "WARNING: Free space on / is ${ROOT_FREE}G (< 45G target)!"
else
    echo "✓ Disk space verification PASSED: ${ROOT_FREE}G free on /"
fi
