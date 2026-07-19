# tech-utils

Debugging and recovery utilities, collected as they get built.

| Utility | Purpose |
| --- | --- |
| [tb-watch](tb-watch/) | Always-on Thunderbolt/NVMe incident recorder (LaunchAgent) + one-shot post-incident forensics for external-storage drops on macOS |
| [icloud-photos-doctor](icloud-photos-doctor/) | Ground-truth iCloud Photos sync diagnosis: stuck-upload detection with rate/ETA, wedged-engine (pending resets) detection, and the escalation ladder from daemon kick to the iCloud re-baseline toggle |

## [tb-watch](tb-watch/)

Always-on incident recorder and post-incident forensics for Thunderbolt/NVMe
storage drops, born from a July 2026 investigation of whole-tower dropouts on
an OWC TB5 hub feeding two Envoy Ultras and a ThunderBlade X8:

- **LaunchAgent recorder** — streams curated kernel events (NVMe fatals,
  PCIe tunnel teardowns, volume unmounts, Thunderbolt switch events) to a
  hard-capped ~50 MB log that survives reboots, so the *mode* of a failure is
  never lost to log-store retention.
- **`tb-forensics.sh [window]`** — one-shot incident report from the unified
  log store: fatals, teardown markers, volume-unmount order, hotplug
  interrupts, current TB tree, sleep/wake history.

The [saga writeup](tb-watch/SAGA.md) reconstructs both captured incidents —
from "drives randomly disconnect" to a named suspect drive, a co-suspect hub,
and the isolation experiment that discriminates them; the
[folder README](tb-watch/README.md) covers install/uninstall and how to read
an incident.

## [icloud-photos-doctor](icloud-photos-doctor/)

Ground-truth diagnosis for iCloud Photos sync, for the days when the Photos UI
says "Last Synced <months ago>" and nothing else — a stuck upload queue has no
indicator at all. One zsh script, read-only by default:

- **`icloud-photos-doctor.sh`** — finds the system library (via `lsof` on
  `photolibraryd`), integrity-checks a safe copy of `Photos.sqlite`, counts
  synced vs awaiting-upload assets and down-sync liveness, measures upload
  movement between runs (slow vs stuck, with rate and rough ETA), and reads the
  sync engine's own state files for the failure signatures: soft resets stuck
  `pending` (blocks all uploads, survives reboots), a dormant outgoing pipeline,
  and attach limbo after an interrupted enable. Prints a verdict with the
  matching escalation: wait out the engine's 2 h refresh interval, `--kick`
  (restart `cloudphotod` — the safe lever for wedge states), or the iCloud
  Photos off→on re-baseline with keep-originals cautions.

Born from a July 2026 investigation of an eight-day silent up-sync wedge; the
[folder README](icloud-photos-doctor/README.md) documents the signatures, the
verdict table, and when each fix applies.
