# RECOVERY PLAYBOOK — AMD Radeon 610M Black Screen

**Hardware**: ASUS ROG Strix G713PV · Ryzen 9 7845HX · RTX 4060 Laptop + Radeon 610M iGPU
**Snapshot location**: `.\snapshots\` (under the repo folder)

## What "working" looks like (snapshot 2026-05-19 00:09:58)

| Item | Value |
|------|-------|
| AMD Radeon 610M | Status=OK, Code=0, driver v32.0.21043.7012 (2026-04-28) |
| NVIDIA RTX 4060 | Status=OK, Code=0, driver v32.0.15.9186 (2026-01-20) |
| BIOS | G713PV.336 (2025-10-01) |
| Modern Standby | DISABLED (PlatformAoAcOverride=0, CsEnabled=0) |
| Hibernate | DISABLED |
| Fast Startup | DISABLED |
| TdrDelay | 30s |
| Sleep states available | Hibernate only (then disabled by us) |
| Active scheme actions | Lid close = nothing; sleep timeout = never |
| GPU Mode | **Ultimate** (panel MUXed directly to RTX 4060 — set 2026-06-14) |
| Panel native res | 2560x1440 @ 240Hz (BOE0B69 internal panel) |

## When the built-in screen goes wrong again

Since the panel is now MUXed to the RTX 4060 (Ultimate), the AMD Code 43 failure
can no longer black it out. Two failure modes remain after a boot:

- **Stuck at 640x480** (panel on, but generic fallback): the driver loaded but
  didn't bind the native mode table. **Non-destructive fix — no reboot needed.**
- **Black panel**: a firmware/MUX init fault. Needs a full **cold** boot.

### Fast path (try in order)

1. **Low-res (640x480)?** Force native resolution — instant, no reboot:
   ```powershell
   cd path\to\DisplayDiagnostics
   .\Recover-Display.ps1 -NoReboot
   ```
   (or the standalone `.\Force-Resolution.ps1`). The auto-recovery task also does
   this automatically at logon.
2. **Black panel?** **Win + Ctrl + Shift + B** — resets graphics stack, no reboot.
3. **Still black? Full COLD boot** (NOT Restart — hold power 10s -> off -> press power).
   A warm restart preserves the half-applied MUX/driver state; only a cold power
   cycle re-inits the MUX cleanly. (Confirmed: cold boot also healed AMD Code 43.)
4. **External monitor**: plug in *after* Windows loads, not at boot — connecting it
   at boot has caused the POST display handoff to fail (ROG logo on ext, then black).

### Permanent fix (DONE 2026-06-14)

**GPU Mode is now Ultimate** — the built-in panel is MUXed directly to the NVIDIA
RTX 4060, completely bypassing the buggy AMD Radeon 610M iGPU. The original Code 43
black-screen failure mode is therefore eliminated. To revert (factory Optimus):
Armoury Crate -> GPU Mode -> Standard, or `.\Set-GpuMux.ps1 -Mode Optimus`, then reboot.

> MUX state read: `(Get-WmiObject -Namespace root\wmi -Class AsusAtkWmi_WMNB).DSTS(0x00090016).device_status`
> -> `0x00010000` = Ultimate, `0x00010001` = Optimus.

## Auto-recovery (refactored 2026-06-13)

The whole boot/watchdog tangle was replaced by a single escalating engine plus a
single scheduled task. The old design never worked for this failure because it
(a) was never actually registered, and (b) explicitly *refused* to act on a dead
AMD iGPU. The new design escalates aggressively and **stops the instant the panel
is lit**.

| File | Purpose |
|------|---------|
| `Recover-Display.ps1` | The recovery engine. Runs an escalating ladder, re-checking panel health after every step, and exits the moment the built-in panel is on. Last resort = reboot (warm restart, then cold shutdown) with loop protection. |
| `Install-AutoRecovery.ps1` | Registers ONE task `Display_AutoRecover_ROG` and removes the old tasks. Run once, as admin. |

**Task `Display_AutoRecover_ROG`**: runs as the logged-in user with *Highest*
privileges (elevated, no UAC) in the interactive session — so it can both inject
`Win+Ctrl+Shift+B` AND cycle devices / reboot. Triggers: **at logon**, **on resume
from sleep** (Power-Troubleshooter ID 1), **on unlock**.

Recovery ladder (stops at the first step that makes the panel usable):
1. **Force native resolution** — `ChangeDisplaySettingsEx` (fixes the common 640x480 stuck case; no admin, non-destructive)
2. GPU stack reset — `Win+Ctrl+Shift+B`
3. `pnputil /scan-devices` + restart GPU services
4. AMD iGPU disable/enable cycle
5. `DisplaySwitch /extend,/clone` mode-set (never `/internal` — that would kill an external display)
6. Re-apply known-good registry (TDR / power / fast-startup off)
7. **Reboot ladder** — warm restart, then full cold shutdown, capped by `MaxRebootAttempts` (default 2) to prevent boot loops. A healthy boot resets the counter.

**"Healthy" now means** the internal panel is active AND at a usable (near-native)
resolution — a panel merely "on" at 640x480 counts as not-yet-recovered, so the
resolution fix runs.

Manual use: `.\Recover-Display.ps1 -NoReboot` runs only the software steps (safe mid-session).

### Other scripts

| File | Purpose |
|------|---------|
| `Capture-WorkingState.ps1` | Run while things work — writes a timestamped snapshot to `snapshots\`. |
| `Restore-FromSnapshot.ps1` | Run when broken — re-applies registry/powercfg + GPU reset cycle. Admin required. |
| `Harden-GPU.ps1` | One-time hardening (TDR, ULPS, D3 cold). Already applied. |

> **Deprecated** (tasks removed, files kept for reference): `Boot-GPU-Guardian.ps1`,
> `Register-BootGuardian.ps1`, `Add-WakeTriggers.ps1`, `GPU-Watchdog.ps1`,
> `Trigger-Failover.ps1`. Superseded by `Recover-Display.ps1` + `Install-AutoRecovery.ps1`.

## Critical notes

- **Splashtop cannot pass UAC.** `PromptOnSecureDesktop=1` — UAC dialogs appear on the secure desktop which remote tools don't see. Use local keyboard or HDMI-out KB/mouse to elevate.
- **Watchdog task was missing** in the latest snapshot — `Restore-FromSnapshot.ps1` will recreate it if `GPU-Watchdog.ps1` is present.
- **AMD driver bug persists across versions** — updating doesn't help. Both old (May 2024) and new (Apr 2026) drivers exhibit the resume crash. Only the MUX switch is a real fix.
