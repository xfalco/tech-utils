# icloud-photos-doctor

Diagnoses iCloud Photos sync from ground truth — `Photos.sqlite` and the sync
engine's own state files — because the Photos UI actively misleads: the
"Last Synced <date>" label at the bottom of the Library view typically shows the
engine's *initial* sync date (months old, looks alarming, means nothing), and a
completely stuck upload queue shows no indicator at all.

Born from a July 2026 investigation: an eight-day up-sync wedge where five soft
resets sat `pending` in the engine's `resetevents.plist`, blocking all uploads
while `syncstatus.plist` reported everything unblocked. Nothing in the UI showed
it; 30 GB of new imports simply never left the Mac. Daemon restarts cleared one
reset; a reboot cleared none; only the iCloud Photos off/on re-baseline fixed it.

## Usage

```zsh
./icloud-photos-doctor.sh              # diagnose (read-only)
# … wait 15+ minutes …
./icloud-photos-doctor.sh              # second run measures upload movement
```

The second run compares against a snapshot in `~/.cache/icloud-photos-doctor/`
and can tell **slow** from **stuck** — including an upload rate and rough ETA.

Flags:

| Flag | Effect |
| --- | --- |
| `--kick` | The safe unwedge: restart `cloudphotod` (SIP blocks `launchctl kickstart`; `killall` works) and reopen Photos. Read-only otherwise. |
| `--library PATH` | Use a specific `.photoslibrary`. Default: whatever `photolibraryd` has open (via `lsof`), falling back to `~/Pictures`. |
| `--logs` | Also scan 30 min of unified log for iCloud-quota errors (slow). |

## What it checks and what the verdicts mean

| Verdict | Meaning | Action |
| --- | --- | --- |
| 🔴 database damaged | `PRAGMA quick_check` failed (e.g. after a drive drop) | Photos → relaunch with Option+Command → Repair Library |
| 🔴 WEDGED | Engine resets `pending` >24 h — uploads unschedulable; survives reboots | `--kick`; if resets persist, toggle iCloud Photos off→on (the re-baseline) |
| 🟠 ATTACH LIMBO | iCloud Photos enabled but engine not attached to the cloud library (interrupted enable / drive drop mid-sync) | `--kick` |
| 🟠 STUCK | Items awaiting upload, zero movement, outgoing pipeline untouched ≥1 h | `--kick`, re-run in 15 min |
| 🔵 RE-BASELINE | Most of the library marked un-synced — normal after the toggle; count climbs then drains | Wait; keep Photos open on AC |
| 🟢 UPLOADING | Awaiting count draining (rate + ETA printed) | Nothing |
| 🟡 no baseline | First run — nothing to compare against | Re-run in 15 min |
| ✅ | Fully uploaded | Nothing |

Also reported every run: synced/awaiting counts, down-sync liveness (items added
in the last 24 h/7 d — proves the *download* direction independently), the
cloud-side asset count vs local, pending reset count and age, outgoing-pipeline
last-touch, and daemon uptimes.

## The toggle (when the doctor says WEDGED and `--kick` didn't clear it)

Photos → Settings → iCloud → uncheck **iCloud Photos** → wait 2–3 minutes →
re-check it. At every prompt choose to **keep / download originals** — never
"Remove from Mac". This discards the engine's client-side sync state (including
stuck reset debt) and re-baselines: it fingerprint-matches every local asset
against the cloud (no re-download, no duplicates), then uploads whatever the
cloud is missing. Expect hours for a large library; this doctor reports the
phase as 🔵 and then 🟢.

Have a verified backup of the library before toggling. Obviously.
