#!/bin/bash
# Benchmark: dduper vs naive SHA256 approach.
# Shows why fetching BTRFS csum-tree checksums is faster than reading file data.
set -e

DDUPER="${DDUPER:-$(pwd)/target/release/dduper}"
IMG="${IMG:-/tmp/dduper_bench.img}"
MNT="${MNT:-/tmp/dduper_bench_mnt}"

# File sizes to test (in MB)
SIZES="1024 5120 10240 20480 51200 102400"

echo "================================================================"
echo "  dduper Benchmark: BTRFS csum-tree vs SHA256 file reading"
echo "================================================================"
echo ""
echo "This benchmark compares two approaches to find duplicate data:"
echo "  1. SHA256 (naive): read entire file contents, compute hash"
echo "  2. dduper:         fetch checksums from BTRFS csum-tree"
echo ""

# Cleanup
sudo umount "$MNT" 2>/dev/null || true
rm -f "$IMG"
mkdir -p "$MNT"

# Create BTRFS image (large enough for 100GB file + copy)
echo "[Setup] Creating 250GB BTRFS image..."
truncate -s 250G "$IMG"
mkfs.btrfs -f "$IMG" > /dev/null 2>&1
sudo mount -o loop "$IMG" "$MNT"
sudo chmod 777 "$MNT"
LOOP=$(findmnt -n -o SOURCE "$MNT")
echo "[Setup] Mounted on $LOOP"
echo ""

# Print header
printf "%-10s | %-14s | %-14s | %-10s\n" \
    "File Size" "SHA256 (naive)" "dduper" "Speedup"
printf "%-10s-+-%-14s-+-%-14s-+-%-10s\n" \
    "----------" "--------------" "--------------" "----------"

for SIZE_MB in $SIZES; do
    SIZE_LABEL="${SIZE_MB}MB"
    if [ "$SIZE_MB" -ge 1024 ]; then
        SIZE_LABEL="$((SIZE_MB / 1024))GB"
    fi

    # Create test files
    dd if=/dev/urandom of="$MNT/bench_src" bs=1M count=$SIZE_MB status=none 2>/dev/null
    cp --reflink=never "$MNT/bench_src" "$MNT/bench_dst"
    sync
    # Drop caches to make SHA256 test fair
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    # Benchmark 1: Naive SHA256 (read full file, compute hash, compare)
    SHA_START=$(date +%s%N)
    sha256sum "$MNT/bench_src" > /dev/null
    sha256sum "$MNT/bench_dst" > /dev/null
    SHA_END=$(date +%s%N)
    SHA_MS=$(( (SHA_END - SHA_START) / 1000000 ))

    # Drop caches again
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    # Benchmark 2: dduper (dry-run)
    cd /tmp
    sudo rm -f dduper.db dduper.log
    DD_START=$(date +%s%N)
    sudo "$DDUPER" --device "$LOOP" --files "$MNT/bench_src" "$MNT/bench_dst" --dry-run > /dev/null 2>&1
    DD_END=$(date +%s%N)
    DD_MS=$(( (DD_END - DD_START) / 1000000 ))

    # Convert to seconds
    SHA_SEC=$(echo "scale=2; $SHA_MS / 1000" | bc 2>/dev/null || echo "N/A")
    DD_SEC=$(echo "scale=2; $DD_MS / 1000" | bc 2>/dev/null || echo "N/A")

    # Compute speedup
    if [ "$DD_MS" -gt 0 ]; then
        SPEEDUP=$(echo "scale=1; $SHA_MS / $DD_MS" | bc 2>/dev/null || echo "N/A")
    else
        SPEEDUP="N/A"
    fi

    printf "%-10s | %12ss | %12ss | %7sx\n" \
        "$SIZE_LABEL" "$SHA_SEC" "$DD_SEC" "$SPEEDUP"

    # Cleanup test files for next iteration
    rm -f "$MNT/bench_src" "$MNT/bench_dst"
    sync
done

echo ""
echo "Speedup = SHA256 time / dduper time"
echo ""
echo "Why dduper is faster:"
echo "  SHA256 must read every byte of both files from disk."
echo "  dduper fetches pre-computed checksums from BTRFS csum-tree"
echo "  (a compact B-tree), avoiding file I/O entirely."
echo ""

# Cleanup
sudo umount "$MNT"
rm -f "$IMG"
sudo rm -f /tmp/dduper.db /tmp/dduper.log
echo "Done."
