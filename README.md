# fanctl

Case fan control for Proxmox hosts, with a fan curve driven by TrueNAS
disk temperatures.

It is built for a common homelab layout: TrueNAS runs as a VM with the
disk controller (HBA) passed through, so the disk temperatures are only
visible inside the VM, while the fans hang off the host's motherboard.
`fanctld` bridges the two.

Two programs:

| | What it does |
|---|---|
| `fanctl` | Manual control. Set a speed as a percentage of measured max RPM. |
| `fanctld` | Daemon. Reads disk temperatures from TrueNAS and drives a curve. |

Speeds are **percentages of real RPM**, not PWM duty. The two are not the
same: fans are far from linear, and a low duty can already mean half the
top speed. `fanctl` measures the fan's ceiling once and closes the loop
on the tachometer.

## Requirements

- A Proxmox VE host.
- Case fans on a 4-pin PWM header that Linux can drive through `hwmon`.
  The installer targets **ITE Super I/O chips** and builds the
  out-of-tree [`it87`](https://github.com/frankcrawford/it87) driver, which
  covers chips the in-kernel driver does not.
- Firmware that lets go of the header (see [Firmware](#firmware)).
- For the curve: TrueNAS with the JSON-RPC WebSocket API (`/api/current`)
  reachable from the host, and an API key.

## Install

For a fresh Proxmox host, `fanctl-install.sh` does everything in one run:
loads the module (building it if needed), offers to find the PWM channel
(or leave it for later with `fanctl pwm`), calibrates, and enables a
systemd unit for either a fixed speed or the TrueNAS curve.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/frangeris/fanctl/main/fanctl-install.sh)"
```

Non-interactive overrides:

| Variable | Meaning |
|---|---|
| `FANCTL_FORCE_ID` | Chip ID passed to `it87` as `force_id`. Defaults to `0x8686` (IT8686E); `sensors-detect` names your chip. |
| `FANCTL_PWM` | PWM channel, skips detection. |
| `FANCTL_SPEED` | Fixed speed in %, skips the mode prompt. |

### Manual install

```bash
git clone https://github.com/frangeris/fanctl && cd fanctl
sudo ./install.sh
```

`install.sh` does no detection. It writes `force_id=0x8686` to
`/etc/modprobe.d/it87.conf` — the value of the
[reference build](#reference-build). On other hardware, use the one-shot
installer, or adjust it before running.

Then, in order:

1. Set up the firmware (below).
2. `fanctl pwm` — finds the channel that drives the fans (see
   [Finding the channel](#finding-the-channel)).
3. `fanctl calibrate` — runs the fan flat out for 15s and records the peak.
4. Pick fixed speed or the temperature curve.

## Firmware

While the BIOS runs its own fan curve on a header, the Super I/O keeps
that header in automatic mode and every PWM write fails with `EBUSY`.
Set the header to a fixed full speed in the BIOS, which disables the
automatic curve and hands the duty register to the OS. On Gigabyte
boards: `M.I.T. → PC Health Status → Smart Fan 5 → <header> → Full Speed`.

"Full speed" does not mean the fans stay loud: they only run at 100%
between POST and the first write from `fanctl`.

## Finding the channel

Do not trust the channel numbers. With a forced chip ID, `pwm1…pwm5` may
not match the silkscreen, and a `fanN_input` can return a responsive,
plausible RPM that has nothing to do with the real fans. The only
reliable test is to change one channel at a time and watch the blades.

`fanctl pwm` walks through it: each channel runs fast, then slow, and you
say whether the fans slowed down. The channel you confirm is saved to
`/etc/fanctl.pwm`, which both `fanctl` and `fanctld` read. If you already
know the channel, `fanctl pwm <n>` sets it directly.

The installer lists the chip's channels: detect, pick one you already
know, or leave it for later. You can run `fanctl pwm` again any time.

Changing the channel clears the calibration — a maximum measured on
another channel's tachometer means nothing — so run `fanctl calibrate`
afterwards. [docs/hardware.md](docs/hardware.md) shows the manual loop.

## Manual use

```bash
fanctl status        # live: speed, channel, chip, mode, TrueNAS setup
fanctl status --once # print it once
fanctl 40            # 40% of max RPM
fanctl max           # 100%
fanctl pwm           # find the channel again
```

Fixed speed at boot:

```bash
systemctl enable --now fanctl.service     # edit the unit to change the %
```

## Temperature curve

With the HBA passed through to TrueNAS, the Proxmox host cannot see the
disks, let alone read their temperatures. `fanctld` queries TrueNAS over
its JSON-RPC WebSocket API and writes the PWM on the host.

```
TrueNAS VM (disk.temperatures)  ──►  fanctld on Proxmox  ──►  pwmN
          JSON-RPC / wss                     sysfs
```

```bash
apt install -y python3-websocket
fanctld init
$EDITOR /etc/fanctld.conf       # TRUENAS_HOST and TRUENAS_KEY
fanctld dry-run                 # reads temps, touches nothing
systemctl enable --now fanctld.service
```

`fanctl status` then shows every disk's temperature and the speed the
curve picked. It reads the daemon's last poll from `/run/fanctld.state`,
so it adds no calls to TrueNAS however often it refreshes.

### The curve

The curve lives in `/etc/fanctld.conf`, as `temp:speed` points where
speed is a percentage of the measured maximum RPM. The hottest disk
picks the point.

```
CURVE=0:35,36:45,40:55,43:70,46:85,50:100
HYSTERESIS=2
POLL=60
```

```bash
fanctld curve                                    # show it
fanctld curve set "0:30,38:45,42:60,46:80,50:100"
fanctld curve hysteresis 3
fanctld curve test 44                            # what would it do at 44C
systemctl restart fanctld                        # apply
```

```
CURVE  hysteresis 2C
  0-35C       35%   [#######.............]
  36-39C      45%   [#########...........]
  40-42C      55%   [###########.........]
  43-45C      70%   [##############......]
  46-49C      85%   [#################...]
  >= 50C      100%  [####################]
```

The first point must be 0 so the curve always has a floor, and speeds
may not decrease as temperature rises; `curve set` refuses anything else
rather than writing a config the daemon would reject on restart.

**Hysteresis** stops the fans stepping up and down every poll when a
disk sits on a boundary. With `HYSTERESIS=2`, a fan already at 85% holds
there until the temperature falls two degrees below the edge of that
band. Raising the speed is never delayed.

For reference, 40–45 °C is a comfortable range for spinning disks;
sustained temperatures above ~50 °C shorten their life.

**Fail-safe.** Three consecutive failed polls force the fans to 100%, and
stopping the service does the same. A TrueNAS VM that dies must never
leave the disks under a stale low fan setting.

Use `fanctl.service` **or** `fanctld.service`, never both — they fight over
the same channel.

## API key

Create it in TrueNAS under the user avatar → API Keys, attached to a
service account with the **Readonly Admin** role. The daemon only reads
temperatures; a full-admin key on the hypervisor buys nothing and risks
the pool. The key lives in `/etc/fanctld.conf`, mode 600, and the daemon
refuses to start if that file is readable by anyone else.

## Troubleshooting

- **Every write fails with `EBUSY`.** The BIOS still owns the header; see
  [Firmware](#firmware).
- **The RPM reading moves but the fans do not.** Wrong channel; see
  [Finding the channel](#finding-the-channel).
- **Fans do not stop at 0%.** A 4-pin fan without zero-RPM support idles
  at its minimum. Normal.
- **Fans sound different after a kernel upgrade.** DKMS rebuilds `it87`
  for each new kernel; if the build lags, control falls back to the BIOS.

## Reference build

Developed and tested on a **Gigabyte B450M DS3H V2** (ITE IT8686E, one
system fan header feeding a PWM hub) running TrueNAS as a VM with an HBA
passed through. The bring-up notes — the chip without an upstream driver,
the BIOS handoff, why its channel turned out to be `pwm2` and how the
tachometer lied on `pwm1` — are in [docs/hardware.md](docs/hardware.md),
and double as a worked example for bringing up a new board.
## Uninstall

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/frangeris/fanctl/main/fanctl-install.sh)" -- --uninstall
```

Running the installer on a host that already has fanctl offers the same
choice. It removes the binaries, units, config and DKMS module.

**Set the BIOS back to `Normal`** afterwards. The header was left in Full
Speed so the OS could own it; with nothing driving it, the fans sit at
100% until the BIOS takes the curve back.

