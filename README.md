# BC-250 partial core unlock — use the good fused-off cores, park the bad one

The AMD BC-250 (Cyan Skillfish APU) ships with 6 of its 8 Zen 2 cores enabled. The known unlocks
([rw-r-r-0644/bc250-core-unlock](https://github.com/rw-r-r-0644/bc250-core-unlock),
[Hexxeh/bc250-efi-core-unlock](https://github.com/Hexxeh/bc250-efi-core-unlock)) rewrite the core
presence mask to `0xFF` and assume all 8 cores work. On some boards one of the two fused-off
cores is **genuinely defective**: the machine hard-hangs the moment Linux brings it up.

This repo covers that case. It enables the mask anyway, boots Linux with `maxcpus=1`, and brings up
every CPU **except** the defective core's two threads. On the reference board that gives
**7 cores / 14 threads** instead of 6/12, persistent across cold boots, with no reboot loop.
It also fixes the missing CPU C-states / cpufreq that affect every BC-250 on the stock BIOS.

> **7, not 8.** If all 8 of your cores are good, the upstream tools already do the job. This is for
> boards where one isn't.
>
> **It can't help if core 0 is the bad one.** Under mask `0xFF` the firmware always boots on core 0
> (APIC 0), so a defective core 0, or any defect that crashes the firmware's own startup rather than
> Linux's CPU bring-up, hangs POST before GRUB or Linux runs. Parking only works for cores Linux
> would otherwise bring up itself. Step 2 below detects this safely. Read the whole README first. You are poking undocumented SMU/firmware
> interfaces on your own hardware. There is no warranty. See [LICENSE](LICENSE).

## How it fits together

| Piece | What it does | Where |
|---|---|---|
| `maxcpus=1` kernel arg | Linux boots on cpu0 only, so the bad core is never touched by the kernel's SMP bring-up | `rpm-ostree kargs` |
| `bc250-cpu-online` + systemd unit | Early in boot (before `sysinit.target`), onlines every CPU except `PARKED_APICS`; checks the ACPI MADT and each CPU's APIC ID, aborts on anything unexpected; never reboots | `sbin/`, `systemd/`, `etc/` |
| Patched Hexxeh EFI shim | On a cold boot (factory mask) writes `0xFF` and warm-resets **once** (NVRAM loop guard); on `0xFF` returns immediately | `efi/` |
| GRUB `console.cfg` hook | Chainloads the shim before the boot menu; also points GRUB's `early_initrd` at the ACPI cpio | `grub/` |
| ACPI early cpio | `_CST` + `_PSS` for `\_PR.P000–P00F` from [mendesrr/bc250-acpi-fix-updated-8c](https://github.com/mendesrr/bc250-acpi-fix-updated-8c) | `acpi/` |
| `bc250-core-test` | Tests one core at a time under `maxcpus=1` to find the defective one | `sbin/` |
| `bc250-acceptance` | stress-ng `--verify` run with a telemetry CSV and a kernel-log check | `tools/` |

Written for **Bazzite / Fedora Atomic** (rpm-ostree, bootupd static GRUB with BLS). On other distros
the ideas carry over; paths (`/var/usrlocal`, `/boot/grub2`) and the karg command differ.

## Things we learned the hard way (BIOS P3.00)

- **`efibootmgr` entries don't survive a cold boot.** The AMI firmware deletes custom boot entries
  and resets `BootOrder` from its own `DefaultBootOrder` variable. So the shim README's NVMe install
  (a firmware boot entry) silently never runs. Chainloading from GRUB works.
- **The hook must run before greenboot.** GRUB runs twice on a cold boot (before and after the shim's
  reset). In `custom.cfg` (after `08_greenboot`) that would decrement the boot counter twice.
  `console.cfg` is sourced in the pre-stage, before greenboot.
- **GRUB script has no `&&`.** `chainloader X && boot` doesn't work, so use `if chainloader X; then boot; fi`.
- **No C-states on any stock BC-250.** The firmware's CPU SSDT scopes `_CST` to `\_PR.C000–C00F`, but
  the processors are `\_PR.P000–P00F`, so the table fails to load (`Could not resolve symbol
  [\_PR.C000]` in dmesg) and `cpuidle` has no driver. mendesrr's tables fix it. On bootupd systems,
  don't use their `grub2-mkconfig` instructions. Fedora's GRUB honours an `early_initrd` variable,
  which the hook sets.
- **APIC layout.** Under mask `0xFF`, logical CPU *n* = APIC ID *n* = core *n/2*, SMT siblings adjacent.
  Under a factory mask the firmware packs enabled cores per CCX (e.g. `0xD7` → APIC 0–5, 8–13), so
  don't infer physical cores from APIC IDs there.
- The SMU mailbox (PCI 00:00.0, 0xB8/0xBC) is shared with `cyan-skillfish-governor-smu`. **Stop the
  governor before any OS-side SMN access** (the unlock tool), and restart it after.
- **Cold boot = rollback.** PSU off / unplugged ≥ 60 s restores the factory mask.

## Procedure

Steps 1–3 find your defective core. Steps 4–6 make the result persistent. Test between steps.
All `sudo` commands below change your system; read them first.

### 0. Prerequisites

- Secure Boot off (the BC-250 firmware doesn't support it anyway: `mokutil --sb-state`).
- `stress-ng`, `acpica-tools` (`iasl`), `cpio`. For building the shim: a Fedora distrobox with
  `mingw64-gcc make git`.
- Your **factory mask**: run the rw-r-r-0644 tool without `-f` (governor stopped). It prints
  `core presence mask: 0x000000XX`. Standard boards read `0x77`. A different value (the reference board:
  `0xD7`) means the factory fused off a different pair of cores, and quite possibly for a reason.
  Fused-off cores are the zero bits: `0xD7 = 1101 0111` → cores **3 and 5**.

### 1. Onlining service + `maxcpus=1` (safe on any mask)

```bash
sudo install -m 0755 sbin/bc250-cpu-online /usr/local/sbin/
sudo install -m 0644 etc/bc250-cpu-online.conf /etc/        # leave PARKED_APICS empty for now
sudo install -m 0644 systemd/bc250-cpu-online.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable bc250-cpu-online.service
sudo rpm-ostree kargs --append-if-missing=maxcpus=1
sudo bc250-cpu-online --dry-run                               # should say "mode factory mask"
systemctl reboot
```
Expect the same CPU count as before (e.g. 12), brought up by the service:
`journalctl -b -u bc250-cpu-online`.

### 2. Force `0xFF` once, by hand

```bash
sudo systemctl stop cyan-skillfish-governor-smu
sudo ./bc250-unlock-cores.py -f          # in your rw-r-r-0644/bc250-core-unlock checkout
```
**Warm** reboot (not a power cycle). At the GRUB menu press `e`, append `bc250.cpuonline=0` to the
`linux` line, then Ctrl-X. You'll boot on cpu0 only, with the mask at `0xFF`
(`cat /sys/devices/system/cpu/possible` → `0-15`).

**Stop condition:** if this warm reboot doesn't reach the GRUB menu (POST hangs, black/green screen),
the problem is in core 0 or in the firmware's own bring-up, and **this method can't work on your board**.
Power-cycle (PSU off ≥ 60 s) to get the factory mask back, remove `maxcpus=1`, and stop here.
**Never install the shim (step 4) on such a board.** It would make every cold boot hang after its
warm reset, and GRUB runs the hook before you could turn it off, so recovery would need a live USB.

### 3. Find the defective core(s)

Test only the fused-off cores (zero bits of your factory mask). Core 0 can't be tested or parked,
because it's the boot CPU (see the stop condition above).
```bash
sudo sbin/bc250-core-test 3        # core 3 = cpu6/cpu7
sudo sbin/bc250-core-test 5        # core 5 = cpu10/cpu11
```
Each run syncs, onlines the two threads, checks their APIC IDs, runs a 120 s `stress-ng --verify`
pinned to them, and offlines them again. **A defective core usually hangs the machine instantly**
(black/green screen). Power-cycle (PSU off ≥ 60 s), note the core, and redo step 2 for the next one.
Treat a verify failure as defective too.

Then set the parked APIC IDs = `2N 2N+1` for each bad core *N*, e.g. core 5:
```bash
echo 'PARKED_APICS="10 11"' | sudo tee /etc/bc250-cpu-online.conf
```
(If every core passed, use `PARKED_APICS=none` and you probably don't need this repo.)
Redo step 2 and warm-reboot **without** the GRUB edit. The service should online everything
except your parked threads. Run `grep apicid /proc/cpuinfo` to confirm.

### 4. Pre-OS mask: patched EFI shim via GRUB

Build (inside the Fedora distrobox), with **your** factory mask:
```bash
git clone --recurse-submodules https://github.com/Hexxeh/bc250-efi-core-unlock
cd bc250-efi-core-unlock && git checkout 3e45131
git apply ../bc250-partial-core-unlock/efi/bc250-efi-core-unlock-factory-mask.patch
make mingw FACTORY_MASK=0xD7            # <- your value; the build refuses without it
```
The patch (against 3e45131, the version *before* upstream added SMU firmware patching) makes the
shim trigger only on your exact factory mask. It uses the same Q3 `0x98` write as the rw-r-r-0644
tool, adds a one-reset **loop guard** (if the mask doesn't survive the warm reset it gives up for
that power-on and boots with the factory mask), and records the outcome in the NVRAM variable
`BC250CoreUnlockStatus-648e8930-3211-4c04-8b0a-b2de736856cb` (`10` = unlocked after reset,
`E1`–`E6` = errors, see `main.c`).

Install (ESP = `/boot/efi`, find its UUID with `lsblk -f`):
```bash
sudo mkdir -p /boot/efi/EFI/bc250
sudo cp bc250-unlock.efi /boot/efi/EFI/bc250/COREUNLOCK.EFI
sed "s/@ESP_UUID@/XXXX-XXXX/" grub/console.cfg > /tmp/console.cfg     # your ESP UUID
sudo grep -q console.cfg /boot/grub2/grub.cfg && sudo install -m 0600 /tmp/console.cfg /boot/grub2/console.cfg
```
(Check that `/boot/grub2/console.cfg` doesn't already exist first. If it does, merge by hand.)

Test: warm reboot (mask is `0xFF`, so there should be no extra reset), then a **cold boot**. Expect one
extra POST, then the full CPU count. Check with
`od -An -tx1 /sys/firmware/efi/efivars/BC250CoreUnlockStatus-*` and `sudo grub2-editenv list`
(`bc250_grub=returned`).

### 5. ACPI C-states / P-states

```bash
acpi/build-acpi-cpio.sh                  # clones mendesrr @ reviewed commit, compiles the .dsl
sudo install -m 0644 bc250-acpi.cpio /boot/bc250-acpi.cpio
```
The GRUB hook from step 4 already sets `early_initrd` when that file exists. Reboot, then check:
`dmesg | grep 'Table Upgrade'` (two `HACK` SSDTs),
`cat /sys/devices/system/cpu/cpuidle/current_driver` → `acpi_idle`, states `POLL C1 C2 C3`,
`scaling_driver` → `acpi-cpufreq` (800–3200 MHz). The leftover `\_PR.C00x` errors are the
firmware's broken table and are harmless.

### 6. Verify under load

```bash
tools/bc250-acceptance 20 cpu            # stress-ng --cpu <all> --verify, telemetry CSV, dmesg check
# start FurMark (or similar) first, then:
tools/bc250-acceptance 15 combined
```

## Rollback

See [ROLLBACK.md](ROLLBACK.md). Short version: a **cold boot** always restores the factory mask.
`bc250.cpuonline=0` on the kernel line skips the service. `sudo grub2-editenv - set bc250_skip_unlock=1`
/ `bc250_skip_acpi=1` disable the hook's two parts. Deleting `/boot/grub2/console.cfg` removes it.

## Reference board results

BIOS P3.00, factory mask `0xD7` (cores 3 and 5 fused off). Core 3 good, **core 5 hangs on bring-up**
→ `PARKED_APICS="10 11"`. Bazzite (kernel 7.2, Fedora 44), 40-CU GPU unlock active alongside.

| Test | Result |
|---|---|
| Cold boot | 7c/14t, core 5 never onlined, 40/40 CUs, shim status `10` |
| `stress-ng --cpu 14 --cpu-method all --verify`, 20 min | 0 failures, 0 untrustworthy; 3.49 GHz all-core, Tctl plateau 86–88 °C |
| FurMark GL 1080p + the above, 15 min | 0 failures, no amdgpu reset / ring timeout / MCE |
| C-states | `POLL C1 C2 C3` in use on all 14 CPUs |

**Thermals: the combined load is hot.** CPU Tctl sat at **100 °C** for ~14 of 15 minutes (clocks
trimmed 3.49 → ~3.37 GHz) and the GPU at the governor's 85 °C throttle point (FurMark fell from
~63 to ~45 FPS). Nothing failed, but the extra core is extra heat on a shared heatsink. Sort out
airflow before relying on it, or cap the CPU with `scaling_max_freq` (e.g. 2550 MHz = no boost).

Known side effect of mask `0xFF`: amdgpu logs `Unsupported clock type` and GPU clock telemetry reads
nonsense (FurMark/sysfs show 2–100 MHz). Upstream Hexxeh HEAD patches the SMU firmware's metrics
layout for 8 cores, which likely fixes this. Not tested here.

## Credits

- [rw-r-r-0644](https://github.com/rw-r-r-0644/bc250-core-unlock): the core mask discovery and Q3 `0x98` write.
- [Hexxeh](https://github.com/Hexxeh/bc250-efi-core-unlock): the EFI shim this patches (MIT License, Copyright (c) 2026 Liam McLoughlin; the patch in `efi/` stays under those terms).
- [mendesrr](https://github.com/mendesrr/bc250-acpi-fix-updated-8c) and contributors: the C/P-state SSDTs.
- The cyan-skillfish-governor-smu and bc250-cu-live-manager authors, for the GPU side.
