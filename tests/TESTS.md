# Tests

The repository ships three test entry points:

| Script               | Purpose                                                                                      |
|----------------------|----------------------------------------------------------------------------------------------|
| `cargo test`         | Rust unit tests for `csum.rs` and `db.rs` (no BTRFS required).                                |
| `tests/test.sh`      | End-to-end loopback BTRFS smoke test with multiple files and sizes.                           |
| `tests/benchmark.sh` | Compares dduper against naive `sha256sum` on file pairs from 1 GB to 100 GB.                  |
| `tests/verify.sh`    | Minimal interactive verification on a 512 MB loopback image.                                  |

## Continuous integration

`.github/workflows/ci.yml` runs three jobs on every push and PR:

1. **unit-tests** — `cargo fmt --check`, `cargo clippy`, `cargo test`, and `cargo build --release`. Uploads the binary as a workflow artifact.
2. **build-btrfs-progs** — applies `patch/btrfs-progs-v6.11/*.patch` to upstream btrfs-progs, builds the static `btrfs.static`, and uploads it as an artifact. Cached on the patch's content hash so re-runs are fast.
3. **smoke** — a 4 × 3 matrix (`crc32 / xxhash / blake2 / sha256` × `dir / dir-recurse / fast-mode`) that boots a 512 MB loopback BTRFS image, runs `dduper --dry-run` then `dduper`, and asserts that filesystem usage drops by at least 45 MB.

`ci/github/run-smoke.sh` is the wrapper that the smoke matrix invokes.

## Running the smoke script locally

```bash
cargo build --release
sudo install -m755 target/release/dduper /usr/sbin/dduper
sudo install -m755 bin/btrfs.static       /usr/sbin/btrfs.static  # patched btrfs-progs
sudo ./ci/github/run-smoke.sh crc32 dir
```

Replace `crc32` with `xxhash`, `blake2`, or `sha256` to exercise other csum types; replace `dir` with `dir-recurse` or `fast-mode` for the other scenarios.
