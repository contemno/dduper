#!/usr/bin/env bash
#
# Run a single smoke scenario for dduper on a loopback BTRFS image.
#
# Usage: run-smoke.sh <csum_type> <scenario>
#   csum_type: crc32 | xxhash | blake2 | sha256
#   scenario:  dir | dir-recurse | fast-mode
#
# Creates a 512MB loopback BTRFS filesystem with the requested csum type,
# stages two copies of a 50MB random file, runs `dduper --dry-run` then
# `dduper`, and asserts that the post-dedupe filesystem usage drops by
# at least 45MB. Exits non-zero on assertion failure.
#
# Designed to run on a real Linux host with btrfs kernel support
# (e.g. a GitHub Actions hosted runner). dduper and btrfs.static must
# already be installed under /usr/sbin/.

set -eux -o pipefail

CSUM="${1:?csum type required}"
SCENARIO="${2:?scenario required}"

IMG="${IMG:-/tmp/dduper_smoke.img}"
MNT="${MNT:-/tmp/dduper_smoke_mnt}"
SRC="/tmp/dduper_smoke_src"
SIZE_MB=512

cleanup() {
    set +e
    umount "$MNT" 2>/dev/null
    rm -f "$IMG" "$SRC"
    rm -rf "$MNT"
    rm -f /tmp/dduper.db /tmp/dduper.log
    set -e
}
trap cleanup EXIT

cleanup
mkdir -p "$MNT"

truncate -s ${SIZE_MB}M "$IMG"
case "$CSUM" in
    crc32)
        mkfs.btrfs -f "$IMG" >/dev/null
        ;;
    xxhash|blake2|sha256)
        mkfs.btrfs -f --csum "$CSUM" "$IMG" >/dev/null
        ;;
    *)
        echo "Unknown csum type: $CSUM" >&2
        exit 64
        ;;
esac

mount -o loop "$IMG" "$MNT"
LOOP_DEV=$(findmnt -n -o SOURCE "$MNT")

# Generate a 50MB random source file once. Each scenario stages two
# copies on the BTRFS mount; dedupe should reclaim ~50MB.
dd if=/dev/urandom of="$SRC" bs=1M count=50 status=none

stage_two_dirs() {
    local dir1="$MNT/d1" dir2="$MNT/d2"
    mkdir -p "$dir1" "$dir2"
    cp "$SRC" "$dir1/f1"
    cp "$SRC" "$dir2/f1"
    sync
    DUPER_ARGS=(--device "$LOOP_DEV" --dir "$dir1" "$dir2")
}

stage_recursive_dirs() {
    local subdir="$MNT/d1/d2/d3"
    mkdir -p "$subdir"
    cp "$SRC" "$MNT/f1"
    cp "$SRC" "$subdir/f1"
    sync
    DUPER_ARGS=(--device "$LOOP_DEV" --dir "$MNT" --recurse)
}

DUPER_FLAGS=()
case "$SCENARIO" in
    dir)
        stage_two_dirs
        ;;
    dir-recurse)
        stage_recursive_dirs
        ;;
    fast-mode)
        stage_two_dirs
        DUPER_FLAGS=(--fast-mode)
        ;;
    *)
        echo "Unknown scenario: $SCENARIO" >&2
        exit 64
        ;;
esac

before=$(df --output=used -BM "$MNT" | tail -1 | tr -d ' M')

cd /tmp
rm -f dduper.db dduper.log
dduper "${DUPER_FLAGS[@]}" "${DUPER_ARGS[@]}" --dry-run
rm -f dduper.db dduper.log
dduper "${DUPER_FLAGS[@]}" "${DUPER_ARGS[@]}"
sync
sleep 2

after=$(df --output=used -BM "$MNT" | tail -1 | tr -d ' M')
deduped=$(( before - after ))

echo "scenario=$SCENARIO csum=$CSUM before=${before}M after=${after}M deduped=${deduped}M"

if [ "$deduped" -lt 45 ]; then
    echo "FAIL: expected ~50MB reclaimed, got ${deduped}MB" >&2
    exit 1
fi
echo "PASS"
