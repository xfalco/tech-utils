# The iCloud Photos up-sync saga

How "why hasn't my 30 GB import uploaded?" became a three-day forensic
investigation of Apple's CloudPhotoLibrary (CPL) sync engine, two full
re-baselines, one self-inflicted wound, and the doctrine now encoded in
[icloud-photos-doctor.sh](icloud-photos-doctor.sh). Written for future-me, for
the next time the Photos UI smiles blandly while nothing uploads.

**Window:** 2026-07-18 → 2026-07-20 · **Machine:** MacBook Pro M4 Max, macOS 26.5.2 (25F84)
**Outcome:** fixed — 80,576 assets synced, awaiting-upload 0.
**Root cause (client side):** soft reset events stuck `pending` since 2026-07-10
blocked all outgoing scheduling; post-mortem verdict is a CPL scheduler bug in
this macOS build (inert daemon instances, no public fix at the time).

## Cast

| Piece | Detail |
| --- | --- |
| The library | `Photos Library.photoslibrary` on an external TB5 SSD ("SecondLifeSSD"), ~80k assets, iCloud Photos on, Download Originals |
| The trigger | 8,961 freshly imported assets (~30 GB) from the [shared-album-rescue](https://github.com/xfalco/shared-album-rescue) project — the first Mac-side up-sync demand in months |
| `photolibraryd` | Owns the library; serves PhotoKit; restarting it is disruptive but safe with Photos closed |
| `cloudphotod` | The CPL engine — sync scheduling, CloudKit sessions. The protagonist and the problem. SIP blocks `launchctl kickstart`; plain `killall` works |
| `Photos.sqlite` | Ground truth. `ZCLOUDLOCALSTATE` per asset: 0 = awaiting upload, 1 = synced. `ZADDEDDATE` proves down-sync liveness |
| CPL state dir | `<library>/resources/cpl/cloudsync.noindex/` — `resetevents.plist`, `syncstatus.plist`, `lastsyncafterlaunch.plist`, `outgoingRecordComputeStates/`, `cpl_enabled_marker` |
| Co-plot | The [tb-watch](../tb-watch/) Thunderbolt dropout saga — a hub-wide drive disconnect landed mid-fix and complicated act two |

## How it surfaced

Photos' Library view read **"Last Synced on Jan 13, 2026"** — six months stale —
with no upload indicator of any kind, while 8,961 items sat unuploaded for 10+
hours (overnight, then 2 h with Photos open on AC). The label turned out to be
a red herring: it shows the engine's `initialSyncDate` (the January library
migration), not sync recency. The UI offers literally nothing that
distinguishes "all done" from "upload queue frozen for a week."

## The forensic trail

1. **Census before theory.** `ZCLOUDLOCALSTATE` said 71,315 synced / 8,961
   awaiting — exactly the new imports. `ZADDEDDATE` showed assets arriving every
   month all year: down-sync alive, up-sync dead. Not an account problem, not a
   network problem — a scheduling problem.
2. **The engine's own diary.** In `cloudsync.noindex/`: `resetevents.plist`
   held **five soft resets, cause "client library version reset in a pull
   session," all `pending: true` since 2026-07-10 21:09** — eight days. The
   outgoing pipeline's working dir (`outgoingRecordComputeStates/`) was last
   touched the same day. While resets are pending, no outgoing work is
   scheduled. Meanwhile `syncstatus.plist` cheerfully reported budgets fine and
   `unBlockedReason => 1`, and the unified log showed the engine wasn't even
   *attempting* work. Wedged, silent, self-satisfied.
3. **Kick #1 works — once.** `killall cloudphotod` (kickstart is SIP-blocked);
   the fresh instance completed the launch-sync **six seconds** after spawning
   (the old instance had refused all morning) and processed exactly **one** of
   the five resets (~5 CPU-minutes), then went dormant. Kicks #2 and #3 (with
   Photos closed, `photolibraryd` restarted too) cleared nothing. A **full
   reboot** cleared nothing — the pending resets are on disk and the fresh boot
   deferred them just the same.
4. **Server cross-check.** `syncstatus.plist` exposed cloud-side asset counts:
   72,382 in iCloud vs 80,276 local — the cloud genuinely lacked the imports.
5. **Toggle #1 (the designed fix).** iCloud Photos off → on discards CPL client
   state wholesale — reset debt included — and re-baselines. It worked…
   *and then every external drive dropped at once* (the tb-watch bus collapse)
   mid-attach, leaving `iCloudLibraryExists => false` with the enabled marker
   present: **attach limbo**. One more kick after remount attached it, the
   re-baseline re-marked ~80k assets, fingerprint-matched them back down in
   ~2 h (no data transfer, no duplicates), and real uploads drained 8,961 →
   4,994.
6. **The self-inflicted wound.** At 4,994 the count sat flat for 14 minutes;
   the freshly written doctor called it STUCK and I kicked. Wrong. The upload
   session lives in the running `cloudphotod`'s memory; the kill orphaned it.
   Every instance born afterwards was **inert**: 0.15 s of CPU over hours,
   launch-syncs fine, zero outgoing work. The `refresh.interval = 7200 s`
   theory ("it'll resume within 2 h") failed. A forced outgoing change (
   favorite-toggle on one asset — CPL *must* push it) was ignored: the engine
   was deaf to every trigger. Overnight maintenance windows: nothing.
   `softwareupdate`: no macOS fix available.
7. **Toggle #2, with doctrine.** Done in a stable-drive window, and afterwards
   **nothing was touched** — no kicks, no nudges, one living instance. Re-marked
   80,433, matched fast (most of the library already fingerprint-known), and
   drained straight through the old floor to **0 awaiting** by 2026-07-20.

## Theories killed along the way

| Theory | Killed by |
| --- | --- |
| iCloud storage full | 4 TB free of 6 TB (user-confirmed); no quota errors in logs |
| Needs Photos open / AC power | 2 h open on AC, zero movement; budgets all true |
| Permissions / TCC | Grants confirmed; engine synced metadata happily throughout |
| Big-batch indigestion (8,961 at once) | Config allows 50k imports/day; the wedge predated the batch by a week |
| Video-transcode boundary | Remaining queue was an ordinary photo/video mix |
| Server-side throttle | Empty `feedbackmessages.plist`; drain later ran full speed |
| "Fresh daemon resumes within refresh.interval (2 h)" | Kicked instance did nothing for 3+ h — post-kill instances are inert, period |
| Reboot fixes everything | Pending resets persisted straight through it |

## Architecture notes (the reference part)

- **State lives in three places:** per-asset flags in `Photos.sqlite`
  (`ZCLOUDLOCALSTATE`), engine state files in
  `resources/cpl/cloudsync.noindex/`, and — crucially — **in-memory session
  state inside the running `cloudphotod`**. The first two survive restarts; the
  third does not, and losing it mid-upload-phase can cost you the whole drain.
- **Soft resets** are the engine scheduling its own re-baseline after a
  client/server library-version mismatch. `pending: true` entries block
  outgoing work until processed — and in this build, they simply never were.
- **The re-baseline (toggle)** re-marks every asset un-synced, then
  fingerprint-matches against the cloud (metadata-only, fast, no duplicates,
  nothing re-downloads) and uploads the unmatched remainder. Counts *climb
  before they drain* — that's the signature, not a regression.
- **Reading sync truthfully costs one safe copy:** copy the sqlite trio
  (`Photos.sqlite`, `-wal`, `-shm`) somewhere scratch, open read-only, count
  `ZCLOUDLOCALSTATE`. Never open the live database.
- **`lastsyncafterlaunch.plist` is a liveness canary:** if Photos has been open
  for minutes and this file predates its launch, the engine is not responding
  to the app at all.

## Doctrine (what the doctor now encodes)

1. Never trust the Photos UI on sync state; the label shows `initialSyncDate`.
2. Diagnose from the database + CPL state files; measure movement across two
   runs before declaring anything stuck.
3. `--kick` (killall cloudphotod + reopen Photos) is for **wedge states**:
   pending resets, attach limbo, a launch-sync that won't run.
4. **Never kill cloudphotod during an active upload phase.** If it was draining
   recently, wait — the pause is probably a burst gap.
5. When resets stay pending through kicks and a reboot, stop negotiating: the
   iCloud Photos off→on re-baseline is the designed reset. Do it in a window
   with stable drives, then keep your hands off until the queue hits zero.
6. Have a verified backup before the toggle. (It's metadata-only and safe — but
   the backup is what makes that sentence relaxing.)

## Act two: the import that would not import (Jul 20–21)

After the upload wedge was beaten, a follow-on task — import 7 photos into the
library — surfaced a *second*, deeper class of failure and turned into an
exhaustive multi-day investigation. Documented here because the conclusion is
the important part: **this specific setup — an ~80k-item, 2.3 TB Photos library
on an external TB5 SSD, synced to iCloud, on macOS 26.5.2 — is genuinely fragile,
and no amount of coaxing made Photos' import reliable.**

### What was tried, and ruled out

Every import (GUI, AppleScript, and a synthetic throwaway image) failed. The
failure was never the files — verified valid JPEGs, 6000×4000, decoding cleanly.
Ruled out, each on evidence:

| Suspected cause | How it died |
| --- | --- |
| The specific files / format / quarantine | A brand-new synthetic image failed identically; quarantine-stripped local copies failed too |
| Google-Drive source location | Failed the same from a local copy and from the library's own volume |
| Silent no-op (nothing happening) | Each attempt threw a modal "Cannot Import Item" dialog — a retry loop piled up ~dozens overnight (a real self-inflicted mistake; retry loops that trigger modals are harmful) |
| Photos mid-sync gating imports | Persisted long after `sync-status` showed the library fully synced |
| Disk space (the literal error) | Library volume 2.5 TB free, boot volume 595 GB, **no** local snapshots holding purgeable space, volume writable |
| Confused internal library state | A full **Repair Library** (⌥⌘ on launch, ~hours) did **not** fix it |

### The real error, and the wall

Widening the dialog's Reason column (after the accessibility route needed an app
restart to take effect) revealed the full text, previously truncated:

> **There was an error attempting to free up disk space for import.**

Photos runs a "free up disk space" routine before every import. On this library
that routine *errors* — not "insufficient space," but the routine itself failing
— even with terabytes free. It survived a Repair Library. That is the wall: a
system-level space-management bug in Photos on this configuration, not anything
fixable from userspace.

### The items that couldn't sync — unreliable down to the count

A restart cleared the stuck banner but left "Couldn't Sync **22** Items to
iCloud," and clicking **View** crashed Photos outright (`EXC_BREAKPOINT` in
`-[NSApplication reportException:]` off an `NSTextView` mouseDown — an AppKit UI
bug reacting to the set, *not* data corruption). On a later View the same alert
listed only **10**. The count itself is unreliable — one more UI-vs-reality gap.

Per the database (ground truth), 22 assets sit at `ZCLOUDLOCALSTATE = 4`, all
shared-album-rescue imports: ~2048px **Live Photos** (still + motion component),
appearing as 11 filename pairs. These are **not** low-value — they are exactly
the rescued family moments the project exists to save. (An earlier draft of this
saga wrongly called them deletable duplicates; correcting that here — the
mischaracterization came from reading DB dimensions and duplicate filenames
without weighing that they're irreplaceable Live Photos.) The pairing is a real
dedup gap in the importer: a photo in two shared albums has two cloud GUIDs but
one original, and the importer deduped by GUID + filename/time against the
*existing* library, so two copies both new-to-library in one batch slipped
through. Fix recorded in shared-album-rescue: dedup within-batch by original
filename + capture time. Cleanup is a careful **review**, not a blind delete: the
`group-unsyncable` command gathers the state-4 assets into an album so the owner
can keep the keepers and prune only true duplicates, avoiding the crashing View
button.

### The Thunderbolt angle (the co-plot, revisited)

The owner's hypothesis — charging the MacBook at up to 240 W *and* running
high-bandwidth library sync down a single OWC TB5 cable through the hub — is
sound for the *drive-disconnect* incidents ([tb-watch](../tb-watch/) logged bus
events during this window) and worth fixing for stability (give the SSD its own
port; charge the Mac separately). But it is **not** the import failure's cause:
the SSD read perfectly throughout, and the import error is Photos software, not
drive I/O.

### Verdict

Exhaustively investigated across ~3 days: database forensics, engine state
files, unified logs, crash traces, volume/snapshot/purgeable-space accounting,
daemon CPU/network sampling, a full library repair, and PhotoKit capability
probes. The upload wedge was real and fixable (see act one). The import failure
was **not** fixable from userspace on this setup and is best routed around: add
photos from an **iPhone/iPad on the same iCloud account** (which also supports
contributing to shared albums, unlike the Mac's PhotoKit), and let them sync
down. When a large external-SSD iCloud library on this macOS build starts
misbehaving, the honest first move is to stop fighting the Mac.

**The strongest single pattern, decisive on its own: the Photos UI was wrong at
nearly every turn.** "Last Synced Jan 13" (months stale), "Syncing 79,465" then
"21,882" frozen over an idle, already-synced engine, "Downloading 164" stuck
while the engine's download counter read 0, "Couldn't Sync 22" that becomes 10
on click, and a View button that crashes. The simplest hypothesis that fits all
of it is that **this is a buggy Photos release** (macOS 26.5.2, a relatively new
OS) — a systemic UI-vs-engine unreliability that *compounds* the external-SSD /
large-library fragility rather than being separate from it. Practical takeaway
for anyone debugging this: **trust the database and the engine state files, never
the Photos UI.** That single rule is what `icloud-photos-doctor` automates.

## Related

- [icloud-photos-doctor.sh](icloud-photos-doctor.sh) — all of the above as a
  runnable verdict.
- [shared-album-rescue](https://github.com/xfalco/shared-album-rescue) — the
  project whose 30 GB import exposed the wedge; its `sync-status` command grew
  from the same forensics.
- [tb-watch](../tb-watch/) — the Thunderbolt dropout saga that body-checked
  toggle #1.
