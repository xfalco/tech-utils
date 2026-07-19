# tb-watch

Always-on incident recorder and post-incident forensics for Thunderbolt/NVMe
storage drops on macOS. Built (Jul 2026) while chasing repeated whole-domain
PCIe collapses on an OWC Thunderbolt 5 Hub feeding two Envoy Ultras and a
ThunderBlade X8. The full investigation — both captured incidents, the PCI
topology decode, and the drive-vs-hub differential — is written up in
[SAGA.md](SAGA.md).

## Pieces

- `tb-watch.sh` — `log stream` with a curated predicate (NVMe fatals, command
  timeouts, PCIe hotplug/teardown markers, APFS volume unmounts, Thunderbolt
  switch events), appending to `~/Library/Logs/tb-watch.log`. Disk use is
  hard-capped at ~50 MB worst case: the log rotates to `tb-watch.log.1`
  whenever it passes 25 MB (checked every 5 minutes), and the previous `.1`
  is discarded. Normal volume is a few KB/hour, so months fit in one file.
- `com.tech-utils.tb-watch.plist.template` + `install.sh` — LaunchAgent that
  keeps the recorder running across logins and reboots (`KeepAlive`).
- `tb-forensics.sh [window]` — one-shot incident report straight from the
  unified log store (works even where tb-watch wasn't running; the store
  retains default-level kernel events for days). Default window: `3h`.

## Install / update / remove

    ./install.sh              # install or update; prints agent state
    ./install.sh --uninstall

The generated plist embeds absolute paths — re-run `install.sh` if this repo
moves.

## Turning it off

    launchctl bootout gui/$(id -u)/com.tech-utils.tb-watch  # pause; revives at next login
    ./install.sh --uninstall                                # stop and remove for good

Log files live at `~/Library/Logs/tb-watch.log{,.1}`; delete them freely once
an investigation is over.

## Reading an incident

Run `./tb-forensics.sh 3h` right after a drop (or read the tb-watch log). Two
signatures to distinguish:

- **Drive-level fatal**: `IONVMeController::FatalHandling ... PCI link down ...
  CSTS=0xffffffff` — one device fell off its link; only its volume unmounts.
  Note: all-ones reads mean *device or path* dead — it does not by itself
  prove the drive (vs. the hub port behind it) is at fault.
- **Domain collapse**: `apciec[...]::disableGated disabling`, cascade of
  `marking child ... dead`, then `Marking ... as needing hardware reset` —
  macOS killed the entire tunneled-PCIe domain; every enclosure on the hub
  drops at once while the Thunderbolt fabric (`system_profiler
  SPThunderboltDataType`) typically stays trained and USB stays alive.

Recovery after a domain collapse: unplug the upstream TB cable at the Mac,
wait ~10 s, replug (this delivers the hardware reset the kernel flagged).
Then First Aid the volumes and validate any SoftRAID array.
