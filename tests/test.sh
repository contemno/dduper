#!/bin/bash
# Test script: creates a BTRFS image, generates test files, runs dduper.
set -e

DDUPER="${DDUPER:-$(pwd)/target/release/dduper}"
IMG="/tmp/dduper_test.img"
MNT="/tmp/dduper_mnt"
SIZE_MB=512

echo "=== dduper test ==="

# Cleanup
sudo umount "$MNT" 2>/dev/null || true
rm -f "$IMG"
mkdir -p "$MNT"

# Create BTRFS image
echo "[1/5] Creating ${SIZE_MB}MB BTRFS image..."
truncate -s ${SIZE_MB}M "$IMG"
mkfs.btrfs -f "$IMG" > /dev/null 2>&1
sudo mount -o loop "$IMG" "$MNT"
sudo chmod 777 "$MNT"

# Get the loop device
LOOP_DEV=$(findmnt -n -o SOURCE "$MNT")
echo "       Mounted on $LOOP_DEV"

# Create test files (50MB each, identical content)
echo "[2/5] Creating test files..."
dd if=/dev/urandom of="$MNT/file1" bs=1M count=50 2>/dev/null
cp "$MNT/file1" "$MNT/file2"
cp "$MNT/file1" "$MNT/file3"
# Create a partially different file
cp "$MNT/file1" "$MNT/file4"
dd if=/dev/urandom of="$MNT/file4" bs=1M count=10 conv=notrunc 2>/dev/null

sync
echo "       Created 4 test files (3 identical, 1 partial match)"

# Check disk usage before
BEFORE=$(df --output=used "$MNT" | tail -1 | tr -d ' ')
echo "       Disk used before dedupe: ${BEFORE}KB"

# Test dry-run
echo ""
echo "[3/5] Testing dduper (dry-run)..."
cd /tmp
sudo rm -f dduper.db dduper.log
DRY_START=$(date +%s%N)
sudo "$DDUPER" --device "$LOOP_DEV" --dir "$MNT" --dry-run 2>&1 || echo "(dry-run exited with error)"
DRY_END=$(date +%s%N)
DRY_MS=$(( (DRY_END - DRY_START) / 1000000 ))
echo "       Dry-run took: ${DRY_MS}ms"

# Test actual dedupe
echo ""
echo "[4/5] Running dduper (actual dedupe)..."
sudo rm -f dduper.db dduper.log
DEDUPE_START=$(date +%s%N)
sudo "$DDUPER" --device "$LOOP_DEV" --dir "$MNT" 2>&1 || echo "(dedupe exited with error)"
DEDUPE_END=$(date +%s%N)
DEDUPE_MS=$(( (DEDUPE_END - DEDUPE_START) / 1000000 ))
echo "       Dedupe took: ${DEDUPE_MS}ms"

sync

# Check disk usage after
AFTER=$(df --output=used "$MNT" | tail -1 | tr -d ' ')
echo "       Disk used after dedupe: ${AFTER}KB"
SAVED=$(( BEFORE - AFTER ))
echo "       Space saved: ${SAVED}KB"

# Summary
echo ""
echo "[5/5] === SUMMARY ==="
echo "       Dry-run:     ${DRY_MS}ms"
echo "       Dedupe:      ${DEDUPE_MS}ms"
echo "       Space saved: ${SAVED}KB"

# Cleanup
sudo umount "$MNT"
rm -f "$IMG"
sudo rm -f dduper.db dduper.log
echo ""
echo "Done."
