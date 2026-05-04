FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ovmf qemu-system qemu-efi \
        ca-certificates curl gcc libc6-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install the Rust toolchain so setup_repos.sh can `cargo build --release`
# the dduper binary on the host before staging it into the QEMU rootfs.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal \
    && rustc --version && cargo --version
