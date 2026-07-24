# The Thunderbolt dropout saga

How "one of my drives randomly disconnects sometimes" became a four-incident
forensic investigation with a named suspect, a co-suspect, a running
experiment — and, finally, a conviction. Written for future-me.

**Window:** 2026-07-17 → 2026-07-24 · **Machine:** MacBook Pro M4 Max, macOS 26.5.2 (25F84)
**Status: CLOSED — EyeOfSauron convicted (incident #4).** On a direct,
hub-free connection it reproduced the instant-kill signature solo, while the
tower ran clean without it. Hub exonerated (every additional quiet tower-day
is confirmation). Remaining: RMA the drive, file the OWC ticket.

## Cast

| Piece | Detail |
| --- | --- |
| Hub | OWC Thunderbolt 5 Hub, FW 62.2 — also powers the laptop (~140 W upstream PD) |
| "EyeOfSauron" | OWC Envoy Ultra TB5 4 TB, blade reports `OWC Aura Pro IV` FW `ERFM12.0`, SN `121218P2190117`. The chronically-dropping "idle" drive. Prime suspect. |
| "SecondLifeSSD" | OWC Envoy Ultra TB5 4 TB, **same** FW `ERFM12.0`, SN `121218P219014E`. Hosts the Photos library backing store. Never the one that drops. |
| "Alexandria" | ThunderBlade X8 32 TB (TB3, FW 68.2): 8 Phison blades FW `ELFM10.0`, SoftRAID mirror (kext 8.6). Hosts Google Drive. |
| Topology | Everything behind the hub's single upstream cable → one TB bus (Bus 0), one shared tunneled-PCIe domain. Shared fate by construction. |
| Also in the room | Amphetamine (trigger: AC + home wifi), Ejectify, Backblaze, Spotlight — the last two keep "idle" volumes under constant background I/O. |

## How it started

Chronic annoyance: one Envoy — ironically the one *not* actively used — would
periodically disconnect. On **2026-07-17 ~12:44** it escalated: all three
enclosures vanished simultaneously. Hub LED on, drives cool, laptop awake.

Every intuitive theory died on contact with the logs:

- **Not power.** The hub was charging the Mac through the same cable the whole
  time (battery 56 % → 99 % across the incident). The "laptop wasn't on its
  charger" observation was true and irrelevant — the hub *is* a charger.
- **Not sleep.** Awake with display on since 12:06:58; Amphetamine assertions held.
- **Not the cable/ports.** The killer observation: after the collapse the
  kernel still held live USB assertions for the hub and both Envoys, and
  `system_profiler` showed the **Thunderbolt fabric fully trained** (hub
  80 Gb/s, Envoys 80, ThunderBlade 40) while `diskutil` showed **zero external
  disks**. Physical link fine, USB fine, power fine — only the tunneled-PCIe
  layer was dead. Everything that followed built on this.

## Incident #1 — 2026-07-17, the slow spiral

| Time | Event |
| --- | --- |
| ~12:09 | Tower plugged in; PD negotiation flaps ~40 s; Mac starts charging via hub |
| 12:10:05 | Early warning: EyeOfSauron's first mount attempt **fails** (`0x0000004D`), APFS notes "reloading after unclean unmount" (scars from earlier hard drops), two `AppleNVMe Assert failed: (fTerminated == false)` |
| 12:21–12:29 | Enumeration completes, all volumes mount |
| 12:34:14 | `IONVMeController::CommandTimeout` on PCI `50:0:0` — mid-**write** |
| 12:34:18 | The money line (below); only disk13/14 — EyeOfSauron — removed. Everything else keeps working |
| 12:34–12:40 | Kernel resets/re-probes the hub PCIe bridge 4× (`reset probe child ranges`) |
| 12:44:10 | Hotplug flap on that subtree (`now present 0` → `present 1`) |
| 12:44:36 | `apciec[pcic0-bridge]::disableGated` → every device in the domain marked dead in ~1 ms (10 NVMe controllers + XHCI) → `Marking pcic0-bridge as needing hardware reset`. Total loss. |

The money line:

```
IONVMeController::FatalHandling(): 3rd party NVMe controller. PCI link down. Write.
MODEL=OWC Aura Pro IV FW=ERFM12.0 CSTS=0xffffffff US[1]=0x0 US[0]=0x23 VID=0xffff DID=0xffff
```

`CSTS/VID/DID = all-ones` → config-space reads returned nothing: the
controller — **or the path to it** — fell off the bus. (That parenthetical
became important on day two.)

**Identification.** PCI topology decode: each Envoy = one Phison
`0x1987:0x5027` behind an Intel `0x8086:0x5786` (Barlow Ridge) bridge set —
EyeOfSauron on hub PCIe port `2:0:0`, SecondLifeSSD on `2:2:0`; the
ThunderBlade = Intel `0x15ef` (Titan Ridge) → 2× ASMedia `0x1b21:0x2806`
switches → 8× Phison `0x1987:0x5021`, on `2:1:0`. The faulting device was the
`2:0:0` Envoy, and APFS named it in the same millisecond as the fatal:
`disk14s1 unmounting volume EyeOfSauron … requested by: kernel_task`.
Post-remount serial mapping sealed it. Also matched the user-known pattern:
the historically-dropping drive is the non-Photos one.

**Verdict after #1** (later revised): drive guilty; hub merely the amplifier
(shared domain = shared blast radius).

## Recovery playbook (validated twice)

1. Unplug the upstream TB cable **at the Mac end**, wait ~10 s, replug — this
   delivers the hardware reset the kernel flagged; tunnels rebuild, volumes
   remount. (Power-cycling drives is rarely needed; the fabric never dropped.)
2. First Aid saying `could not unmount … (-69565)` is **contention, not
   damage** — fseventsd/Backblaze/Spotlight hold the volume. Fix:
   `diskutil unmount force diskNsM` → `diskutil verifyVolume diskN` → remount.
   EyeOfSauron's APFS verified fully clean after #1 despite ≥3 hard removals.
3. SoftRAID-validate Alexandria; open Photos once to let it self-check.

## Incident #2 — 2026-07-18, the instant kill (plot twist)

Clean reboot at 12:25, 78 quiet minutes, then at **13:44:06.757** a
Thunderbolt switch notification — and **22 ms later** the kernel probed the
hub's **top-level** PCIe bridge (`1:0:0`) and found it dead. No
`CommandTimeout`. No `FatalHandling`. No single-drive prologue. The entire
domain was marked dead in ~1 ms; volumes force-unmounted within 650 ms
(EyeOfSauron → Alexandria → SecondLifeSSD — teardown order, not causal
order). Same end state as #1: fabric trained, USB alive, PCIe gone.

Notes: identical switch notifications fired harmlessly at 13:11, 13:18,
13:36; `ThunderboltAccessoryUpdaterService` woke 16 min prior
(likely-coincidental, logged for pattern-watching). `disksleep 0` was already
set — it did not prevent this (consistent: #2 had no idle-drive prologue).

**Why this changed the verdict:**

- #1 was drive-shaped (10-minute spiral from one device). #2 was hub-shaped
  (spontaneous bridge death, zero warning).
- `CSTS=0xffffffff` proves *unreachable*, not *guilty* — a dying hub port
  produces the same all-ones reads as a dying drive.
- Both days orbit hub PCIe port `2:0:0` — EyeOfSauron's slot. If the **port**
  is the flaky element, whatever drive sits there inherits the blame… which
  would also explain the original irony (the *idle* drive kept dropping).

**Hub promoted to co-suspect.**

## Incident #3 — 2026-07-20, boot-time repeat (instant kill ×2)

A restart with everything still attached. Clean shutdown (all three volumes
unmounted politely at 22:53:23), clean boot at 22:53:40, login at ~23:03 —
SoftRAID loads, runs its SMART pass (**"No disks failed the SMART test"**),
volumes mount. Twelve seconds later:

| Time | Event |
| --- | --- |
| 23:03:21.8 → 27.280 | Three TB switch notifications (`event_code = 38`) over ~6 s |
| 23:03:27.302 | **22 ms** after the last notify: `apciec disableGated` → hub top bridge `1:0:0` **dead** → volumes killed by `kernel_task` within 6 s → `needing hardware reset` |
| 23:03:27 | SoftRAID: all 8 blades "removed or stopped responding while the volume was mounted and in use", volume error `E00002E4` |
| ~23:17 | Replug **without** EyeOfSauron (physically removed) — clean re-enumeration, tower back at full speed |

Takeaways:

- Identical fingerprint to #2 — notify → 22 ms → bridge death, zero NVMe
  precursor — now seen twice, under opposite conditions (78 quiet minutes
  into an afternoon vs. 12 s into the post-login mount rush). Score:
  instant-kill ×2, drive-fatal spiral ×1.
- The drives passed SMART **three seconds before** the domain died — healthy
  by their own account. "Failing disk" in the classic sense is dead as a
  theory (SMART can't see controller-firmware hangs, but it rules out the
  ordinary kind).
- EyeOfSauron was attached but produced no device-level event; nothing ties
  it to this one. Formally non-discriminating, evidentially hub-leaning.
- tb-watch survived the reboot and pinned the moment. Known limitation
  observed: `log stream` drops messages during event storms, so
  `tb-forensics.sh` / `log show` (the unified store) remain the full record —
  the recorder's job is the timestamp and the guarantee, not the whole story.

## Incident #4 — 2026-07-23, the conviction (solo repro on a direct port)

The reintroduction arm, run in its strongest form: EyeOfSauron moved out of
the tower entirely and plugged **directly into a Mac port** — its own
Thunderbolt bus, its own PCIe domain (`pcic2`; the hub only ever lived on
`pcic0`), no hub silicon in the path. Within about a day, with the Mac fully
awake on AC and no sleep transition anywhere near:

    23:12:09.836  apciec[pcic2-bridge]::disableGated disabling
    23:12:09.837  dead child at [i4]1:0:0(0x8086:0x5786)
    23:12:09.844  disk18s1 unmounting volume EyeOfSauron, requested by: kernel_task
    23:12:09.869  Marking pcic2-bridge as needing hardware reset

Only its private domain died. SecondLifeSSD and Alexandria on the hub never
blinked — the macOS notification named EyeOfSauron and *only* EyeOfSauron.

Why this closes the case:

- **The signature transferred to the drive.** The instant-kill pattern —
  first-hop Intel `0x8086:0x5786` bridge dead → `disableGated` → `needing
  hardware reset` — was the strongest hub evidence, because in the tower that
  first hop was the hub's chip. But the Envoy Ultra carries its **own**
  Barlow Ridge controller, and on a direct connection *that* is the first
  hop — and it died identically, solo. The drive doesn't just hang its NVMe
  blade (incident #1); it kills its own Thunderbolt controller (the
  #2/#3 shape). It was attached for every tower event, and it produces both
  signatures alone.
- **The ledger.** Tower with EyeOfSauron: 3 collapses in 4 days. Tower
  without it: zero events since 2026-07-20 23:17. EyeOfSauron alone on a
  pristine port: dead within ~a day. Every configuration containing the
  drive fails; every configuration without it doesn't.
- **No confounders.** Different port, different domain, no hub, machine
  awake, SMART historically clean.

**Verdict: EyeOfSauron guilty on all four incidents; hub exonerated.** The
RMA unit is conveniently indivisible — blade, controller, and captive cable
travel together, so whichever of the three is at fault, all of it goes back.

Epilogue, and the reason this folder exists: when cross-checking this event
the next morning, the unified log store had **already rolled past it** — even
14-day queries returned nothing on this log-heavy machine. The sole surviving
record of the decisive event of the investigation is
`~/Library/Logs/tb-watch.log`. Retention insurance, cashed in.

## The two models

- **A — drive-centric:** EyeOfSauron's blade hangs (idle transitions and/or
  under write); #1 was a polite hang, #2 a hang that instantly wedged the
  hub's switch. Supported by #1's isolated phase and the 12:10 mount failure.
- **B — hub-centric:** the hub's PCIe switch is flaky; its `2:0:0` port
  degrading intermittently *manufactured* the drive's bad reputation, and #2
  was the switch dying outright. One explanation covers both days.

**Resolution (2026-07-24): Model A wins.** Incident #4 showed the drive
reproducing the "hub-shaped" signature with no hub present, and the tower ran
clean once the drive left.

## The discriminator (concluded)

**Concluded 2026-07-23** — the reintroduction arm fired first: connected
directly to a Mac port, EyeOfSauron killed its own private domain (incident
#4) while the tower stayed clean without it. Drive convicted, hub cleared.
The original setup for reference: unplug
EyeOfSauron **at the hub end** — its cable is captive only at the drive end,
and it's bus-powered, so pulling the hub-side connector is full electrical
absence with zero unracking. Then:

| Condition | Outcome | Verdict |
| --- | --- | --- |
| Unplugged | Collapse happens anyway | **Hub guilty** — failed with the suspect absent |
| Unplugged | Days of silence | **Drive guilty** by elimination (base rate was 2 collapses in 2 days + chronic history) |
| Reintroduced on the **other** Envoy port | Trouble resumes | Drive sealed as culprit, port exonerated |
| Reintroduced, quiet on new port, acts up only on `2:0:0` | | Hub port guilty |

**Unmounting is not a substitute**: an unmounted drive stays powered,
enumerated, and idling on the shared fabric — historically this drive's most
dangerous regime — and a controller hang still triggers the same kernel
recovery with the same blast radius. Electrical absence or nothing.

## Mitigations & changes made

- `sudo pmset -a disksleep 0` (was 10). The pmset warning about disk sleep vs
  system sleep is ancient advisory boilerplate; setting verified applied.
- **tb-watch** LaunchAgent + `tb-forensics.sh` (this folder): captures the
  *mode* of the next failure (the experiment's actual data), survives
  reboots, hard-capped ~50 MB. The unified log store only retains a few days
  on this machine's chatty workload — the recorder is retention insurance.
- SoftRAID ≥ 8.6.1 (8.3/8.5 changelogs added disconnect resilience; SoftRAID
  does not *cause* these — reproducible per OWC with unformatted disks).
- macOS 26.5.2 is current; the 26.3 external-storage regression was fixed in
  26.4 — not a factor here.

## Ammunition for the OWC ticket

- Both signatures verbatim: the #1 `FatalHandling … PCI link down …
  CSTS=0xffffffff` line, and #2's spontaneous `1:0:0` bridge death with
  `disableGated` + `needing hardware reset`, 22 ms after a switch notify.
- Serials/firmware: EyeOfSauron `121218P2190117`, SecondLifeSSD
  `121218P219014E`, both blades `ERFM12.0` (identical — so unit- or
  port-specific, not firmware-version); hub FW `62.2` (ask if newer exists);
  ThunderBlade blades `ELFM10.0`.
- No public Envoy Ultra firmware updater exists (OWC Drive Guide only does
  formatting) — a fix ships via support or RMA.
- OWC's own KB acknowledges chain-wide simultaneous ejects as a known
  Thunderbolt-wide issue; the Envoy manual documents bus-power limits on some
  M4 Macs (two bus-powered Envoys share this hub's budget).

## Verdict so far

- [x] Ruled out: power loss, sleep/wake, cable seating, physical link, SoftRAID, filesystem damage, Amphetamine gaps, classic disk failure (SMART all-pass 3 s before incident #3)
- [x] #1 trigger: EyeOfSauron unreachable mid-write → failed kernel recovery collapsed the domain
- [x] #2: spontaneous hub top-bridge death, no drive prologue → hub co-suspect
- [x] #3: same instant-kill fingerprint as #2 (notify → 22 ms → bridge death), EyeOfSauron attached but uninvolved → instant-kill ×2, leaning hub
- [x] Both Envoys on identical firmware → unit- or port-specific
- [x] Isolation run armed for real: EyeOfSauron physically removed 2026-07-20 23:17
- [x] Isolation outcome (2026-07-24): tower clean for 3.5 days without the drive AND the drive reproduced the instant-kill signature solo on a direct port → **EyeOfSauron convicted, hub exonerated**
- [ ] RMA EyeOfSauron (SN `121218P2190117`, FW `ERFM12.0`) — lead with the solo direct-port repro; attach both signatures and the SMART-clean note
- [ ] OWC ticket filed / firmware answers received

**When it happens again:** `./tb-forensics.sh 3h` and/or read
`~/Library/Logs/tb-watch.log`. Recovery: see the playbook above.
