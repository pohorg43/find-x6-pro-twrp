#!/usr/bin/env bash
set -euo pipefail

echo "=== Native CI Disk Cleanup and Memory Optimization ==="

echo "--- 1. Block devices layout (lsblk) ---"
lsblk || true

echo "--- 2. Disk space before cleanup ---"
df -h

echo "--- 3. Stopping docker/snap services and removing root swap ---"
sudo systemctl stop docker.service docker.socket containerd snapd 2>/dev/null || true
if [ -f /swapfile ]; then
    echo "Disabling and removing pre-existing /swapfile on /..."
    sudo swapoff /swapfile 2>/dev/null || true
    sudo rm -f /swapfile 2>/dev/null || true
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
    /usr/share/doc \
    /usr/share/man \
    /var/lib/snapd \
    /snap \
    /var/lib/docker \
    /etc/docker \
    /var/run/docker.sock \
    /var/cache/apt/archives/* \
    /var/lib/apt/lists/* || true

sudo apt-get clean 2>/dev/null || true

echo "--- 5. Configuring Swap: zram without consuming /dev/root ---"
# Check if a separate ephemeral disk is mounted on /mnt with enough space
FREE_MNT=$(df -BG /mnt 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo "0")
if [ -n "$FREE_MNT" ] && [ "$FREE_MNT" -ge 20 ]; then
    echo "Found separate /mnt with ${FREE_MNT}G free. Creating 14G swap on /mnt..."
    SWAP_FILE="/mnt/swapfile"
    sudo fallocate -l 14G "$SWAP_FILE" || sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count=14336
    sudo chmod 600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE"
    sudo swapon "$SWAP_FILE"
else
    echo "No large separate /mnt. Setting up 12G zram swap (zero bytes used on /)..."
    sudo modprobe zram num_devices=1 2>/dev/null || true
    if [ -b /dev/zram0 ]; then
        if grep -q zstd /sys/block/zram0/comp_algorithm 2>/dev/null; then
            echo zstd | sudo tee /sys/block/zram0/comp_algorithm 2>/dev/null || true
        elif grep -q lz4 /sys/block/zram0/comp_algorithm 2>/dev/null; then
            echo lz4 | sudo tee /sys/block/zram0/comp_algorithm 2>/dev/null || true
        fi
        echo 12G | sudo tee /sys/block/zram0/disksize 2>/dev/null || true
        sudo mkswap /dev/zram0
        sudo swapon -p 100 /dev/zram0
    else
        echo "Direct /dev/zram0 failed, installing zram-tools..."
        sudo apt-get install -y --no-install-recommends zram-tools 2>/dev/null || true
        sudo sed -i 's/^#*PERCENT=.*/PERCENT=90/' /etc/default/zramswap 2>/dev/null || true
        sudo systemctl restart zramswap 2>/dev/null || true
    fi
fi

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
