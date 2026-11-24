#!/usr/bin/env bash
set -euo pipefail

echo "=== Native CI Disk Cleanup and Swap Setup ==="

echo "--- Disk space before cleanup ---"
df -h

echo "--- Removing unneeded toolchains & SDKs ---"
sudo rm -rf \
    /usr/share/dotnet \
    /usr/local/lib/android \
    /opt/ghc \
    /opt/hostedtoolcache/CodeQL \
    /usr/local/share/boost \
    /var/lib/apt/lists/* || true

echo "--- Cleaning Docker cache ---"
sudo docker system prune -af || true
sudo rm -rf /var/lib/docker || true

echo "--- Disk space after cleanup ---"
df -h

echo "--- Setting up 14G swap ---"
SWAP_DIR="/mnt"
FREE_MNT=$(df -BG /mnt 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo "0")
if [ -z "$FREE_MNT" ] || [ "$FREE_MNT" -lt 18 ]; then
    echo "/mnt has less than 18G free ($FREE_MNT G), placing swapfile on /"
    SWAP_DIR="/"
else
    echo "/mnt has $FREE_MNT G free, placing swapfile on /mnt"
fi

SWAP_FILE="$SWAP_DIR/swapfile"
if [ ! -f "$SWAP_FILE" ]; then
    echo "Allocating 14G swap at $SWAP_FILE..."
    sudo fallocate -l 14G "$SWAP_FILE" || sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count=14336
    sudo chmod 600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE"
    sudo swapon "$SWAP_FILE"
fi

echo "--- Memory & Swap status ---"
free -h
swapon --show

echo "=== Disk cleanup and swap setup complete ==="
