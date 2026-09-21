# Hardware notes

Findings from getting fan control working on this specific machine.
Most of them cost hours, so they are written down.

## The board

**Gigabyte B450M DS3H V2**, Ryzen 5 3600, Proxmox VE (kernel 7.0.14-17-pve).

Two fan headers, total: `CPU_FAN` and `SYS_FAN1`. No `SYS_FAN2`, no
`CPU_OPT` — confirmed against the official manual's internal-connector
list. Every case fan therefore hangs off one header through a hub.

## The chip has no driver

`sensors-detect` reports:

```
Found `ITE IT8686E Super IO Sensors'   (address 0xa40, driver `to-be-written')
```

That is accurate, not a stale database: the IT8686E is genuinely absent
from `drivers/hwmon/it87.c` upstream. `gigabyte_wmi` reads temperatures
but exposes no PWM and cannot control anything.

The in-tree `it87.ko` ships with Proxmox but will not bind to this chip.
The out-of-tree fork carries the right register map:

```bash
apt install -y dkms build-essential proxmox-default-headers
git clone https://github.com/frankcrawford/it87 /usr/src/it87-git
cd /usr/src/it87-git && make dkms
modprobe it87 force_id=0x8686 ignore_resource_conflict=1
```

`ignore_resource_conflict=1` exists in the module (it is documented in the
kernel's own `it87` page) and avoids needing `acpi_enforce_resources=lax`
on the kernel command line — so no GRUB edit and no reboot. It is not free:
ACPI and the driver then touch the chip in parallel, which the kernel docs
warn can race.

Persist it:

```
/etc/modprobe.d/it87.conf:  options it87 force_id=0x8686 ignore_resource_conflict=1
/etc/modules:               it87
```

DKMS rebuilds on kernel upgrades. If upstream lags a new Proxmox kernel,
fan control silently reverts to the BIOS curve — not dangerous, but worth
knowing when the fans suddenly sound different after `apt upgrade`.

## Smart Fan 5 must release the header

Out of the box every PWM write returns:

```
echo: write error: Device or resource busy
```

The on-die controller owns the header while Smart Fan 5 runs a curve on
it. Set `M.I.T. → PC Health Status → Smart Fan 5 → SYS_FAN1 → Full Speed`.

"Full Speed" does not mean "leave them screaming" — it means *disable the
automatic curve*, which hands the duty register to the OS. The fans run at
100% for the few seconds between POST and whatever `fanctl` writes.

This survives reboots. `pwm2_enable` still reads back `0` afterwards; that
read is wrong, the writes land anyway.

## The channel numbering is wrong

**The single most costly finding.** The chip exposes `pwm1` … `pwm5`. Under
`force_id=0x8686` the mapping does not match the silkscreen, and the
physical `SYS_FAN1` header is driven by **`pwm2`**, not `pwm1`.

Worse, `fan1_input` returns a number that *tracks whatever is written to
`pwm1`* — plausible, responsive, and completely disconnected from the fans.
Writing `pwm1` and watching `fan1_input` produces a self-consistent lie:
the readings move, the fans do not.

It was caught only by ignoring the numbers and looking at the blades. To
re-derive it on other hardware, sweep every channel and watch:

```bash
H=$(dirname $(grep -l it8686 /sys/class/hwmon/hwmon*/name))
for p in 1 2 3 4 5; do
  echo "=== pwm$p ==="
  echo 1 > $H/pwm${p}_enable 2>/dev/null
  echo 255 > $H/pwm$p; sleep 5
  echo 30  > $H/pwm$p; sleep 5
  read -p "did the fans change? [enter] "
  echo 255 > $H/pwm$p
done
```

The loop restores the previous channel to 255 just before testing the next
one, so the channel *after* the real one appears to speed up. Ignore that
echo; only the slow-down is signal.

Once on `pwm2`, `fanctl calibrate` reported 2376 RPM — consistent with the
fans' 2200 RPM rating, which is the confirmation that the tachometer is
finally reading the right thing. On `pwm1` it had reported 1939 RPM,
measuring nothing real.

## The hub was never the problem

Four ID-Cooling 92mm 4-pin PWM fans on an ID-Cooling FH-07 hub: SATA power
from the PSU, one 4-pin signal cable to `SYS_FAN1`.

ID-Cooling's own documentation:

> Each port has its own PWM function and the fan speed can be adjusted at
> the same time, but only the speed of Fan 1 can be identified by the system.

So all seven ports do receive PWM. Only the RPM *reading* is limited to
port 1. A long detour went into suspecting this hub, pricing replacements,
and comparing USB controllers — all of it unnecessary.

Passive hubs cannot do per-fan control, and no cheap one exists: the
category is Corsair, NZXT and Aquacomputer, or DIY. But that was never the
problem here.

## Things that look like faults and are not

- **Fans do not stop at duty 0.** A 4-pin fan without zero-RPM support idles
  at its minimum, around 590 RPM. Normal.
- **A fan cycling on and off** is a fan given too little duty to sustain
  rotation. Keep a floor, or accept the stall.
- **The GPU fan starting and stopping by itself** is the Arc A380's own
  zero-RPM idle. Nothing to do with the board.
- **`pwm2_enable` reading `0`** after a successful write. Cosmetic.
- **`hwmonX` numbers move between reboots.** Everything here resolves the
  path by chip name instead.

## Noise budget

Seven ST4000NM0023 — 7200 RPM SAS enterprise drives — are themselves loud.
When chasing noise, rule the drives out before blaming the fans.
