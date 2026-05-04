How to install dduper?
---------------------

You can install dduper in 3 different ways.

1. Build from source with Cargo.
2. Using Docker image.
3. Using a pre-built binary.

Build from Source:
------------------
`dduper` relies on BTRFS checksums. To expose these checksums to userspace
you need to apply an additional patch on btrfs-progs first. This introduces
a new command to dump csum using `btrfs inspect-internal dump-csum`.

If you are using the latest btrfs-progs you can get the patch from
`patch/btrfs-progs-v6.11/`. Older versions are available under
`patch/btrfs-progs-v*` for compatibility.

Steps:

1. Clone the repo:

   ```
   git clone https://github.com/Lakshmipathi/dduper.git && cd dduper
   ```

2. Apply the patch and build btrfs-progs:

   ```
   git clone https://github.com/kdave/btrfs-progs.git
   cd btrfs-progs
   patch -p1 < ../patch/btrfs-progs-v6.11/0001-Print-csum-for-a-given-file-on-stdout.patch
   ./autogen.sh && ./configure --disable-documentation --disable-libudev
   make && sudo make install
   cd ..
   ```

3. Verify `dump-csum` is available:

   ```
   btrfs inspect-internal dump-csum --help
   usage: btrfs inspect-internal dump-csum <path/to/file> <device>

       Get csums for the given file.
   ```

4. Build the dduper binary with cargo (Rust 1.70+):

   ```
   cargo build --release
   sudo cp target/release/dduper /usr/sbin/dduper
   ```

5. Verify the install and continue with README.md for usage:

   ```
   dduper --help
   dduper --version
   ```

Install using Docker:
---------------------

If you are already using docker and don't want to install any
dependencies, pull the `laks/dduper` image and pass your device and
mount dir like:

```
$ docker run -it --device /dev/sda1 -v /btrfs_mnt:/mnt laks/dduper dduper --device /dev/sda1 --dir /mnt --analyze
```

Make sure to replace `/dev/sda1` with your btrfs device and `/btrfs_mnt`
with the btrfs mount point.

Install pre-built binaries:
---------------------------

The repo ships a statically-linked patched `btrfs.static` under `bin/`
that exposes the `dump-csum` command. You can pair it with a dduper
binary built from source on the same Linux flavor:

```
        git clone https://github.com/Lakshmipathi/dduper.git && cd dduper
        cargo build --release
        sudo cp -v bin/btrfs.static /usr/sbin/
        sudo cp -v target/release/dduper /usr/sbin/dduper
```

After install, type `dduper --help` to list options and continue with
README.md for usage.

Note: For a basic check you can use this
[script](https://github.com/Lakshmipathi/dduper/blob/master/tests/verify.sh).

Misc:
----
If you are interested in dumping csum data, please check this demo:
https://asciinema.org/a/34565

Original mailing-list announcement:
https://www.mail-archive.com/linux-btrfs@vger.kernel.org/msg79853.html
Older patch: https://patchwork.kernel.org/patch/10540229
