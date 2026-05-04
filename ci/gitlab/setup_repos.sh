#!/usr/bin/env bash
#
# Use debian image and setup repos.
set -ex

ci_branch=$1

apt-get update
apt-get -y install git

# Setup rootfs
IMG="/repo/qemu-image.img"
DIR="/target"
mkdir -p $DIR
for i in {0..7};do
mknod -m 0660 "/dev/loop$i" b 7 "$i"
done

# mount the image file
mount -o loop $IMG $DIR

# Pull latest code
rm -rf $DIR/dduper
rm -rf $DIR/btrfs-progs

git clone -b $ci_branch https://github.com/Lakshmipathi/dduper.git $DIR/dduper
touch "$DIR/dduper/$ci_branch"
ls -l "$DIR/dduper/"
git clone https://github.com/kdave/btrfs-progs.git $DIR/btrfs-progs

# Build the Rust dduper binary on the host (rustup is installed in the CI
# image). Doing the build out here keeps the QEMU rootfs free of a Rust
# toolchain and avoids fetching crates from inside the VM.
( cd "$DIR/dduper" && cargo build --release )
ls -lh "$DIR/dduper/target/release/dduper"

cd /
umount $DIR
rmdir $DIR
