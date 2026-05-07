FROM rust:1-bookworm AS rust-build
WORKDIR /src
COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release

FROM debian:bullseye-slim AS btrfs-build
MAINTAINER Lakshmipathi.G

# Install build dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends autoconf automake gcc \
    make pkg-config e2fslibs-dev libblkid-dev zlib1g-dev liblzo2-dev \
    libzstd-dev patch ca-certificates

# Clone btrfs-progs repo
ADD --checksum=sha256:e6512ff305963bc68f11803fa759fecbead778a3a951aeb4f7f3f76dabb31db4 https://github.com/kdave/btrfs-progs/archive/refs/tags/v6.1.3.tar.gz /btrfs-progs.tar.gz

COPY patch/btrfs-progs-v6.1 /patch

# Apply csum patch
WORKDIR /btrfs-progs
RUN tar --strip-components 1 -xzf /btrfs-progs.tar.gz && \
    patch -p1 < /patch/0001-Print-csum-for-a-given-file-on-stdout.patch

# Start the btrfs-progs build
RUN ./autogen.sh
# btrfs-progs 5.14 add an optional dependency (on by default) on libudev, for
# multipath device detection, but that requires a running udev daemon, and
# perhaps ohter changes to make it work inside a Docker container, so it's
# disabled for the moment
RUN ./configure --disable-documentation --disable-libudev
RUN make install DESTDIR=/btrfs-progs-build

# Start the btrfs-progs static build
RUN make clean
RUN make static
RUN make btrfs.static
RUN cp btrfs.static /btrfs-progs-build

# Final runtime image
FROM debian:bullseye-slim
COPY --from=btrfs-build /lib/x86_64-linux-gnu/liblzo2.so.2 /lib/x86_64-linux-gnu/
COPY --from=btrfs-build /btrfs-progs-build /btrfs-progs
COPY --from=rust-build /src/target/release/dduper /usr/sbin/dduper

RUN mv /btrfs-progs/btrfs.static /
RUN cp -rv /btrfs-progs/usr/local/bin/* /usr/local/bin && cp -rv /btrfs-progs/usr/local/include/* /usr/local/include/ && cp -rv /btrfs-progs/usr/local/lib/* /usr/local/lib
RUN btrfs inspect-internal dump-csum --help
RUN dduper --version
