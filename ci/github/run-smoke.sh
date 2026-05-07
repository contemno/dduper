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

set -ex -o pipefail

CSUM="${1:?csum type required}"
SCENARIO="${2:?scenario required}"

IMG="${IMG:-/tmp/dduper_smoke.img}"
MNT="${MNT:-/tmp/dduper_smoke_mnt}"
SRC="/tmp/dduper_smoke_src"
SIZE_MB=512

dump_dduper_log() {
    if [ -f /tmp/dduper.log ]; then
        echo "--- dduper.log ---"
        cat /tmp/dduper.log
        echo "--- end dduper.log ---"
    fi
}

cleanup() {
    set +e
    if [ -d "$MNT" ]; then
        umount "$MNT" 2>/dev/null
    fi
    rm -f "$IMG" "$SRC"
    rm -rf "$MNT"
    rm -f /tmp/dduper.db /tmp/dduper.log
}
trap cleanup EXIT

echo "=== preflight ==="
uname -a
grep -E '\bbtrfs\b' /proc/filesystems || echo "btrfs not in /proc/filesystems yet"
mkfs.btrfs --version || true
ls -la /usr/sbin/dduper /usr/sbin/btrfs.static
file /usr/sbin/dduper /usr/sbin/btrfs.static
dduper --version
/usr/sbin/btrfs.static inspect-internal dump-csum --help

cleanup
mkdir -p "$MNT"

echo "=== mkfs.btrfs (csum=$CSUM, ${SIZE_MB}MB image) ==="
truncate -s ${SIZE_MB}M "$IMG"
case "$CSUM" in
    crc32)
        mkfs.btrfs -f "$IMG"
        ;;
    xxhash|blake2|sha256)
        mkfs.btrfs -f --csum "$CSUM" "$IMG"
        ;;
    *)
        echo "Unknown csum type: $CSUM" >&2
        exit 64
        ;;
esac

echo "=== mount ==="
mount -o loop "$IMG" "$MNT"
LOOP_DEV=$(findmnt -n -o SOURCE "$MNT")
echo "Loop device: $LOOP_DEV"
df -h "$MNT"
btrfs filesystem df "$MNT"

echo "=== stage data (scenario=$SCENARIO) ==="
dd if=/dev/urandom of="$SRC" bs=1M count=50 status=none

D1="$MNT/d1"
D2="$MNT/d2"
SUB="$MNT/d1/d2/d3"

case "$SCENARIO" in
    dir|fast-mode)
        mkdir -p "$D1" "$D2"
        cp "$SRC" "$D1/f1"
        cp "$SRC" "$D2/f1"
        ;;
    dir-recurse)
        mkdir -p "$SUB"
        cp "$SRC" "$MNT/f1"
        cp "$SRC" "$SUB/f1"
        ;;
    *)
        echo "Unknown scenario: $SCENARIO" >&2
        exit 64
        ;;
esac
sync

ls -laR "$MNT"
df -h "$MNT"

before_kb=$(df --output=used "$MNT" | tail -1 | tr -d ' ')
echo "before (KB): $before_kb"

cd /tmp
rm -f dduper.db dduper.log

echo "=== dduper --dry-run ==="
case "$SCENARIO" in
    dir)
        dduper --device "$LOOP_DEV" --dir "$D1" "$D2" --dry-run
        ;;
    dir-recurse)
        dduper --device "$LOOP_DEV" --dir "$MNT" --recurse --dry-run
        ;;
    fast-mode)
        dduper --fast-mode --device "$LOOP_DEV" --dir "$D1" "$D2" --dry-run
        ;;
esac
dump_dduper_log

rm -f dduper.db dduper.log

echo "=== dduper (actual dedupe) ==="
case "$SCENARIO" in
    dir)
        dduper --device "$LOOP_DEV" --dir "$D1" "$D2"
        ;;
    dir-recurse)
        dduper --device "$LOOP_DEV" --dir "$MNT" --recurse
        ;;
    fast-mode)
        dduper --fast-mode --device "$LOOP_DEV" --dir "$D1" "$D2"
        ;;
esac
dump_dduper_log

sync
sleep 2

after_kb=$(df --output=used "$MNT" | tail -1 | tr -d ' ')
echo "after (KB): $after_kb"

deduped_kb=$(( before_kb - after_kb ))
deduped_mb=$(( deduped_kb / 1024 ))
echo "scenario=$SCENARIO csum=$CSUM before=${before_kb}KB after=${after_kb}KB deduped=${deduped_kb}KB (~${deduped_mb}MB)"

btrfs filesystem df "$MNT"
btrfs filesystem usage "$MNT" || true

if [ "$deduped_mb" -lt 45 ]; then
    echo "FAIL: expected >=45MB reclaimed, got ${deduped_mb}MB" >&2
    exit 1
fi
echo "PASS: scenario=$SCENARIO csum=$CSUM"
