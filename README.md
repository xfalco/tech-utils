# tech-utils

Debugging and recovery utilities, collected as they get built.

| Utility | Purpose |
| --- | --- |
| [tb-watch](tb-watch/) | Always-on Thunderbolt/NVMe incident recorder (LaunchAgent) + one-shot post-incident forensics for external-storage drops on macOS |
| [icloud-photos-doctor](icloud-photos-doctor/) | Ground-truth iCloud Photos sync diagnosis: stuck-upload detection with rate/ETA, wedged-engine (pending resets) detection, and the escalation ladder from daemon kick to the iCloud re-baseline toggle |

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
