# Rollback

**Universal: a cold boot (PSU off / unplugged ≥ 60 s) restores the factory core mask.** With the
factory mask the service simply onlines every CPU the firmware lists, so the system is back to stock
behaviour (plus `maxcpus=1`, which the service compensates for).

## Boot hangs or misbehaves

At the GRUB menu press `e` and append to the `linux` line, then Ctrl-X:

- `bc250.cpuonline=0` skips the onlining service (boots on cpu0 only, always safe), or
- `systemd.mask=bc250-cpu-online.service` has the same effect.

Afterwards: `journalctl -b -1 -u bc250-cpu-online`, `journalctl -k -b -1 | grep smpboot`.

If the machine hangs **before** the GRUB menu (the shim), pick the OS directly from the firmware boot
menu, or boot a live USB and delete `grub2/console.cfg` on the /boot partition (or
`EFI/bc250/COREUNLOCK.EFI` on the ESP; the hook then skips because `chainloader` fails). The shim
itself resets at most once per power-on.

## Onlining service

```bash
sudo systemctl disable bc250-cpu-online.service
sudo rm /etc/systemd/system/bc250-cpu-online.service /usr/local/sbin/bc250-cpu-online /etc/bc250-cpu-online.conf
sudo systemctl daemon-reload
```

Remove `maxcpus=1` **only with the factory mask active** (i.e. right after a cold boot, shim removed).
With `0xFF` and no `maxcpus=1`, the kernel brings up the defective core and hangs:

```bash
sudo rpm-ostree kargs --delete=maxcpus=1
```

## Shim / GRUB hook

```bash
sudo grub2-editenv - set bc250_skip_unlock=1     # disable, keep files (unset to re-enable)
sudo rm /boot/grub2/console.cfg                  # remove the hook (also removes the ACPI early_initrd)
sudo rm -r /boot/efi/EFI/bc250
v=/sys/firmware/efi/efivars/BC250CoreUnlockStatus-648e8930-3211-4c04-8b0a-b2de736856cb
[ -e $v ] && sudo chattr -i $v && sudo rm $v     # same for BC250CoreUnlockTry-… if present
```

## ACPI tables

```bash
sudo grub2-editenv - set bc250_skip_acpi=1       # disable (unset to re-enable)
sudo rm /boot/bc250-acpi.cpio                    # remove; the hook skips when the file is absent
```

If a boot fails because of it: `e` at the GRUB menu, remove `../../bc250-acpi.cpio` from the `initrd`
line, Ctrl-X.
