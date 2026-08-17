# Plan: read BTRFS csums via ioctl instead of shelling to btrfs-progs

Status: proposal. Prerequisite: the Rust port (PR #14) is merged.

## Goal

Replace dduper's current "shell out to a patched `btrfs inspect-internal dump-csum`" code path with a direct `BTRFS_IOC_TREE_SEARCH_V2` ioctl that reads the csum tree in-process. After this lands, dduper no longer needs:

- the `bin/btrfs.static` bundled binary (8.1 MB, stale at v5.7),
- the entire `patch/` tree (one patch directory per supported btrfs-progs release),
- the `build-btrfs-progs` job in `.github/workflows/ci.yml`,
- the install-instructions section about applying the patch and building btrfs-progs from source.

dduper becomes a single self-contained Rust binary that works on any mounted BTRFS filesystem with stock btrfs-progs (or with no btrfs-progs at all, since we no longer call it).

## Background

The patched `dump-csum` subcommand (added by `patch/btrfs-progs-v*/0001-Print-csum-for-a-given-file-on-stdout.patch`) is a userspace wrapper that opens the BTRFS device, walks the csum tree, and prints checksums to stdout. dduper currently parses that stdout via a regex (`src/csum.rs:20-28`) and feeds the hex strings into the dedup pipeline.

The problem with that arrangement:

- Each supported btrfs-progs version (v5.6.1, v5.9, v5.12.1, v5.16, v5.18, v6.1, v6.3.3, v6.11) needs a separately-maintained patch because `cmds/inspect.c`, `cmds/commands.h`, and `Makefile` drift between releases.
- Users either compile a patched btrfs-progs themselves (tedious) or trust the bundled `bin/btrfs.static` (stale, may not handle modern csum types correctly).
- Every csum lookup pays for `fork(2) + execve(2) + a stdout pipe + hex parsing`, which is meaningful overhead at directory scale.
- The CI matrix has to include a `build-btrfs-progs` job (~3-5 min cold) even though the only thing dduper actually uses from that artifact is the data the kernel already exposes via ioctl.

## Approach

`BTRFS_IOC_TREE_SEARCH_V2` (`_IOWR(0x94, 17, struct btrfs_ioctl_search_args_v2)`) is a generic "give me items from any BTRFS tree in this key range" ioctl that ships with mainline kernels (stable since 3.0+). It's what `btrfs inspect-internal` uses internally; the patch only exists because upstream btrfs-progs hasn't shipped a user-facing wrapper for the csum-tree case.

### Csum tree shape

BTRFS keeps every checksum in a dedicated b-tree (`BTRFS_CSUM_TREE_OBJECTID = 7`). Items in that tree are keyed by:

| Field      | Value                                                                |
|------------|----------------------------------------------------------------------|
| `objectid` | `BTRFS_EXTENT_CSUM_OBJECTID` = `-10ULL` = `0xFFFFFFFFFFFFFFF6`        |
| `type`     | `BTRFS_EXTENT_CSUM_KEY` = `128`                                       |
| `offset`   | logical byte offset of the start of a contiguous csum run             |

Each item's data is a packed array of N checksums covering N consecutive 4 KB blocks of logical filesystem space. Per-csum width depends on the filesystem's csum type:

| Csum type | Width  |
|-----------|--------|
| crc32c    | 4 B    |
| xxhash64  | 8 B    |
| sha256    | 32 B   |
| blake2b   | 32 B   |

Width is discoverable at runtime via `BTRFS_IOC_FS_INFO` (`csum_type` field) on any open FD on the mount.

### Per-file lookup flow

For each file dduper wants to fingerprint:

1. **`FS_IOC_FIEMAP`** on the file → list of `(logical_offset, length)` extents on the BTRFS volume.
2. **`BTRFS_IOC_TREE_SEARCH_V2`** on any FD that's on the mount, scoped to:
   ```
   tree_id          = BTRFS_CSUM_TREE_OBJECTID (7)
   min/max objectid = BTRFS_EXTENT_CSUM_OBJECTID
   min/max type     = BTRFS_EXTENT_CSUM_KEY
   min_offset       = extent.logical_offset
   max_offset       = extent.logical_offset + extent.length
   ```
   For each returned item, the `header.offset` is where the run starts and `header.len / csum_width` is the count of csums in that run.

The kernel returns matching items packed into a caller-provided buffer; on buffer-full the caller advances `min_offset` past the last returned item and re-invokes.

## Implementation sketch

```rust
// New module: src/btrfs.rs

const BTRFS_IOCTL_MAGIC: u8 = 0x94;
const BTRFS_IOC_TREE_SEARCH_V2: libc::c_ulong = 0xc0709411;
const BTRFS_IOC_FS_INFO:        libc::c_ulong = 0x8400941f;

const BTRFS_CSUM_TREE_OBJECTID:    u64 = 7;
const BTRFS_EXTENT_CSUM_OBJECTID:  u64 = (-10i64) as u64;
const BTRFS_EXTENT_CSUM_KEY:       u32 = 128;

#[repr(C)]
struct SearchKey {
    tree_id:      u64,
    min_objectid: u64, max_objectid: u64,
    min_offset:   u64, max_offset:   u64,
    min_transid:  u64, max_transid:  u64,
    min_type:     u32, max_type:     u32,
    nr_items:     u32, _pad:         [u32; 9],
}

#[repr(C)]
struct SearchHeader { transid: u64, objectid: u64, offset: u64, ty: u32, len: u32 }

#[repr(C)]
struct SearchArgsV2 { key: SearchKey, buf_size: u64, /* flexible buf follows */ }

pub fn csum_width(mnt_fd: RawFd) -> io::Result<usize> {
    // BTRFS_IOC_FS_INFO -> map csum_type to width
}

pub fn dump_csums(
    mnt_fd: RawFd,
    logical_start: u64,
    logical_end: u64,
    csum_width: usize,
) -> io::Result<Vec<u8>> {
    // Loop:
    //   build SearchArgsV2 with min_offset = cursor
    //   ioctl BTRFS_IOC_TREE_SEARCH_V2
    //   parse N (header, item_data) pairs out of the returned buffer
    //   append item_data to out
    //   if nr_items == 0 or last header.offset + (header.len/csum_width)*4096 >= end: break
    //   else cursor = last header.offset + 1
}
```

Then in `src/csum.rs`, replace `do_btrfs_dump_csum` with a thin wrapper that:

1. Opens the file → calls `FS_IOC_FIEMAP` to enumerate extents.
2. For each extent, calls `btrfs::dump_csums`.
3. Hex-encodes the raw csum bytes (preserving the `Vec<String>` shape so downstream `csum::get_hashes` is unchanged).

The dedup ioctls (`FICLONERANGE` / `FIDEDUPERANGE` in `src/dedupe.rs:175-191`) are already in this style; the new code is the same shape.

## Per-csum-type handling

Today the code treats csums as opaque hex strings, which means the SHA256 step downstream doesn't care about csum width. The simplest behavior-preserving change is to hex-encode the raw bytes after `dump_csums` returns and feed the result into the existing pipeline unchanged. Detection of the active csum type happens once per filesystem via `BTRFS_IOC_FS_INFO`, cached for the dedup session.

## What this buys

- **Drop `bin/btrfs.static`** — 8.1 MB binary out of the repo.
- **Drop `patch/`** — no per-version btrfs-progs patches to maintain.
- **Drop the `build-btrfs-progs` job** in `.github/workflows/ci.yml` — saves 3-5 min cold per CI run.
- **Drop the subprocess + stdout-parsing path** in `src/csum.rs:39-62`.
- **Drop the install-instructions section** about patching/compiling btrfs-progs (`INSTALL.md`).
- **Faster** in-process — no fork/exec/text-parsing per file.
- dduper becomes a single self-contained Rust binary; root + `CAP_SYS_ADMIN` are still required, but those were already required for the dedup ioctls themselves.

## What it costs

- ~200-300 lines of new Rust covering `SearchKey`, `SearchHeader`, `SearchArgsV2`, the fs-info path, the search loop, item parsing, and the FIEMAP wrapper.
- Test surface widens — need to validate against all four csum types, multi-extent files, fragmented csum runs, and the buffer-full corner case where one SEARCH_V2 call doesn't cover an extent.
- One new ABI commitment to mainline `BTRFS_IOC_TREE_SEARCH_V2`. Stable since kernel 3.0+, very low risk.

## Prior art

[**bees**](https://github.com/Zygo/bees) — production-grade userspace BTRFS dedupe daemon — uses exactly this pattern. C++ rather than Rust, but the corner cases it handles (item splits across multiple SEARCH_V2 calls, extent-vs-csum-range mismatches, the four csum widths) translate directly. Worth reading `src/bees-roots.cc` and `src/bees-resolve.cc` while writing the Rust version.

## Phased rollout

1. **Add `src/btrfs.rs`** with `BTRFS_IOC_FS_INFO`, `FS_IOC_FIEMAP`, and `BTRFS_IOC_TREE_SEARCH_V2` wrappers as pure unit-testable functions taking `RawFd` + offsets. Mock-friendly via dependency injection or a `BtrfsFd` newtype. Land this with unit tests for the parsing logic against captured/synthetic kernel output.

2. **Add a parallel csum source** in `src/csum.rs` — e.g. `btrfs_dump_csum_ioctl(file, mount_fd) -> Vec<String>` that returns the same shape as the current `do_btrfs_dump_csum`. Gate it behind a `--legacy-dump-csum` flag (default off) for one release; the subprocess path stays as a safety net.

3. **CI matrix can stay as-is** for that release — the 4 × 3 smoke matrix exercises both paths through the same scenarios. Optionally add a fifth matrix axis (`csum_source: ioctl|subprocess`) to lock both in.

4. **Once green**, delete:
   - `do_btrfs_dump_csum` in `src/csum.rs`
   - the `--legacy-dump-csum` flag
   - `bin/btrfs.static`
   - `patch/` (entire tree)
   - the `build-btrfs-progs` job in `.github/workflows/ci.yml`
   - the patch + btrfs-progs build sections in `INSTALL.md`, `DESIGN.md`, `ARCHITECTURE.md`
   - the `dduper-static` install path in the public `Dockerfile` (the `btrfs-build` stage can also be dropped from the Docker image).

## Effort estimate

- 1-2 days for a working SEARCH_V2 path that passes the existing smoke matrix.
- 1-2 more days hardening corner cases (multi-extent files, fragmented csum runs, the four csum widths, large files where one SEARCH_V2 call doesn't cover everything).
- 0.5 day for cleanup commits (deletions, doc updates).

Net repo footprint after step 4: probably halves. The whole "patched btrfs-progs" lore stops being part of dduper's onboarding story.

## Out of scope

- Switching to a kernel-side dedup mechanism that doesn't need userspace csum reads at all. BTRFS doesn't expose one today; any future `BTRFS_IOC_DEDUPE_BY_CSUM` (hypothetical) would supersede this entire plan.
- Cross-volume dedup. SEARCH_V2 is scoped to one mount, same as today.
- Single-file block deduplication (already a known limitation; orthogonal).
