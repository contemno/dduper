# Plan: dduper as an idle-aware daemon

Status: proposal. Prerequisite: the Rust port (PR #14) is merged. Independent of the csum-tree ioctl plan, but composes with it.

## Goal

Add a `dduper daemon` subcommand that runs as a long-lived process and dedupes opportunistically when the system + the BTRFS device are idle, instead of relying on a cron / systemd-timer schedule. The existing one-shot CLI stays untouched and serves as the "force scan now" path.

## Why this is worth considering

A scheduled run is simple but blunt: it fires at 03:00 whether or not the filesystem is currently serving a backup, a build job, or a database. An idle-aware daemon yields to real workloads automatically, can react to new files within seconds of them being written, and amortises dedupe work into many short bursts rather than a few long ones.

The Linux primitives needed already exist in mainline; this plan is a design exercise rather than a research project.

## Architecture

Three concerns, kept separate:

1. **Detect idle.** Decide when it's safe to do work.
2. **Watch for candidates.** Maintain a queue of files worth deduping.
3. **Throttle within active work.** Run as a low-priority citizen so contention mid-batch causes graceful backoff, not contention.

### 1. Idle detection

Three signals, AND-ed together with hysteresis:

| Signal                            | Source                          | Notes                                                                                         |
|-----------------------------------|---------------------------------|-----------------------------------------------------------------------------------------------|
| IO pressure                       | `/proc/pressure/io` (PSI)       | Kernel 4.20+. Supports `poll(2)` with kernel-side thresholds — no polling loop required.       |
| CPU load                          | `/proc/loadavg`                 | Coarse but cheap. `load1 < 0.5 * ncpu` is a reasonable "system is quiet" gate.                 |
| Concurrent BTRFS heavy ops        | `btrfs balance status`, scrub   | Don't dedupe while balance/scrub is running; you'll fight the kernel.                          |

The PSI mechanism is the precise modern answer. Writing `some 150000 1000000` to `/proc/pressure/io` and `poll(2)`-ing the FD wakes us only when the 10-second average crosses 15%. That removes both the polling overhead and the sampling drift of the older approaches.

Hysteresis: require ~30 seconds of sustained idleness before opening the gate; close it immediately when any signal goes hot.

### 2. Watching for candidates

Two strategies, used together:

- **inotify / fanotify** on configured roots → react to `CLOSE_WRITE` events, push paths into the work queue. Catches dedup opportunities as they appear. Risk: inotify queue overflow on very busy filesystems; fanotify is heavier but doesn't lose events.
- **Periodic full sweep** as a backstop — every N hours, walk the tree and refresh the SQLite cache. Catches anything inotify missed (events lost during reboots, files written before dduper started, etc.).

dduper already has the SQLite layer. Persisting "filename → last-checksummed-hash" makes redundant inotify events for unchanged files almost free.

### 3. Self-throttling

Even when the gate says "go," dduper should run as a low-priority citizen so a load spike mid-batch backs us off automatically:

- **`ionice -c 3` (idle class)** — kernel only schedules our IO when the device queue is otherwise empty.
- **`Nice=19`** in the systemd unit (or `setpriority(2)` directly).
- **cgroup v2 `IOWeight=10`** (vs default 100) — controls bandwidth share.
- **Granular batching.** Process one file pair, re-check the gate, repeat. So contention mid-50 GB-directory just stops after the next pair instead of after the whole directory.

## Daemon shape

```rust
// new subcommand: `dduper daemon --device /dev/X --root /mnt [--sweep-interval 6h]`

fn run_daemon(opts: DaemonOpts) -> Result<()> {
    let mut queue = WorkQueue::new();
    let mut watcher = inotify::Inotify::init()?;
    watcher.add_watch(&opts.root, WatchMask::CLOSE_WRITE | WatchMask::MOVED_TO)?;
    let psi = PsiPoller::new("/proc/pressure/io", IoThreshold::SomeAvg10(15_pct))?;
    let mut sweep = Timer::new(opts.sweep_interval);

    loop {
        select! {
            evt = watcher.next()              => queue.push(evt.path),
            _   = psi.wait_below()            => drain_while_idle(&mut queue, &opts),
            _   = sweep.tick()                => queue.extend(walk_root(&opts.root)?),
            _   = wait_for(SIGTERM | SIGINT)  => break,
        }
    }
    Ok(())
}

fn drain_while_idle(queue: &mut WorkQueue, opts: &DaemonOpts) {
    while gate_open(opts) {
        let Some(item) = queue.pop() else { break };
        if let Err(e) = dedupe_one(item, opts) {
            log::warn!("dedupe error: {e}");
        }
    }
}

fn gate_open(opts: &DaemonOpts) -> bool {
       psi_io_below(opts.psi_threshold)
    && load1_below(opts.load_threshold)
    && !btrfs_balance_running(&opts.device)
    && !btrfs_scrub_running(&opts.device)
}
```

systemd unit:

```ini
[Unit]
Description=dduper opportunistic BTRFS dedupe daemon
After=local-fs.target

[Service]
ExecStart=/usr/sbin/dduper daemon --device /dev/sda1 --root /mnt
Nice=19
IOSchedulingClass=idle
CPUWeight=10
IOWeight=10
ProtectSystem=strict
ReadWritePaths=/mnt /var/lib/dduper /var/log/dduper
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=multi-user.target
```

The `dduper scan` (current single-shot CLI) stays unchanged and bypasses the gate — useful for ad-hoc forced runs.

## Implementation considerations

**Triggering work**: inotify is the right default. fanotify is an option for filesystems that overflow inotify queues — make it a `--watch-mode={inotify,fanotify}` flag if needed.

**Snapshot churn**: BTRFS snapshots create lots of metadata events. The watcher should ignore `.snapshots/` and configurable patterns to avoid storms.

**Backoff on EAGAIN/EBUSY**: the dedup ioctls can return EBUSY when the FS is mid-snapshot or balance. Treat this as a transient and re-queue with exponential backoff.

**State on disk**: the existing `dduper.db` schema works; add a `last_seen_mtime` column so we can detect "file changed since we last hashed it" cheaply.

**Crash safety**: `FIDEDUPERANGE` is verified by the kernel, so a daemon crash mid-dedupe can't corrupt anything. The persistent queue need only be best-effort — on restart, re-walk the roots.

**Logging**: structured logs via `tracing` rather than ad-hoc println, so production deployments can ship them to journald / Loki / etc. cleanly.

**Metrics**: optional `--metrics-listen 127.0.0.1:9100` exposing Prometheus counters (files queued, files deduped, bytes reclaimed, gate-open seconds, gate-closed seconds). Useful for tuning thresholds in production.

**Composes with the csum-tree ioctl plan**: if both land, the daemon never has to fork `btrfs.static` and stays self-contained — important because `fork()` from a long-running daemon doubles process RSS briefly.

## Prior art

[**bees**](https://github.com/Zygo/bees) — production-grade BTRFS dedupe daemon, C++. Battle-tested patterns to crib from:

- cgroup-based throttling (their `crawl` loop)
- scan-state persistence across restarts
- handling of snapshot churn via extent-tree iteration rather than pure inotify
- back-pressure on the FS when balance/scrub is active

A Rust port wouldn't be a clone — bees is extent-tree-driven where dduper is file-tree-driven, and the design constraints differ — but the operational lessons (where to throttle, when to stop, what state to persist) translate directly.

## Phased rollout

1. **Idle gate library** — `src/idle.rs` with `gate_open()`, `wait_for_idle()`, `PsiPoller`. Pure functions on `/proc` paths so they're trivially mockable.
2. **`dduper daemon` subcommand** — minimal shell that takes a config, runs the loop, handles signals. Does a single periodic full sweep, no inotify yet. Validates the gate behaviour against synthetic load (`stress-ng`).
3. **Add inotify watching** — separate commit. Add a `--no-inotify` flag for users who want sweep-only behaviour.
4. **Add the systemd unit** to the repo at `dist/systemd/dduper.service`. Document it in `INSTALL.md`.
5. **Optional: metrics endpoint** behind a Cargo feature flag.

Each step lands as a separate PR with its own tests; nothing in the existing CLI changes.

## Effort estimate

- 1 week for the idle gate, signal handling, and the daemon scaffolding.
- 3-5 days for inotify integration and the work queue.
- 2-3 days for systemd unit + docs + a soak test.
- 2-3 days for metrics (optional).

Roughly 2-3 weeks for a usable v1, another week for hardening corner cases (fanotify fallback, snapshot-storm filtering, back-pressure on `btrfs balance`).

## Tradeoffs vs. cron

| Cron / one-shot                          | Daemon + idle gate                                              |
|------------------------------------------|-----------------------------------------------------------------|
| Predictable, easy to reason about        | Adapts to actual load — fits irregular workloads                |
| Runs even when FS is genuinely busy      | Yields to real work; catches dedupe windows cron would miss     |
| Operationally simpler (no daemon to run) | Long-running process, more state, more failure modes            |
| One scope, no coordination needed        | Has to coordinate with `btrfs balance` / scrub                  |

A daemon is a much bigger maintenance surface than a one-shot tool. Worth doing only if there's actual demand — for many users a cron + the existing single-shot CLI hits 80% of the value at 10% of the complexity. The daemon is most justifiable when:

- the storage is actively serving variable workloads (NAS, file server, mailbox spool),
- new dedup-eligible files arrive throughout the day,
- there's no clean "dead window" when a scheduled run would be safe.

## Out of scope

- Cross-volume dedup. SEARCH_V2 + the dedup ioctls are scoped to one mount.
- Single-file block deduplication (already a known limitation; orthogonal).
- Anything that requires kernel changes. The idle gate runs entirely in userspace.
- A separate daemon-only Cargo crate. The daemon is just another subcommand on the same binary.
