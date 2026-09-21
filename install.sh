#!/bin/bash
# Installs fanctl on a Proxmox host. Run as root from the repo root.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

echo "==> installing binaries"
install -m755 bin/fanctl  /usr/local/bin/fanctl
install -m755 bin/fanctld /usr/local/bin/fanctld

echo "==> making the it87 module persistent"
cat > /etc/modprobe.d/it87.conf <<'CONF'
options it87 force_id=0x8686 ignore_resource_conflict=1
CONF
grep -qx it87 /etc/modules || echo it87 >> /etc/modules
modprobe it87 force_id=0x8686 ignore_resource_conflict=1 2>/dev/null || true

echo "==> installing systemd units"
install -m644 systemd/fanctl.service  /etc/systemd/system/
install -m644 systemd/fanctld.service /etc/systemd/system/
systemctl daemon-reload

cat <<'NEXT'

Installed. Next steps:

  1. BIOS: set the fans to Full Speed.
     Without this the chip keeps the header in automatic mode and
     refuses every write.

  2. fanctl pwm              find the channel that drives the fans

  3. fanctl calibrate        measure max RPM once

  4. Pick ONE of:

     fixed speed:
       sed -i 's|fanctl 40|fanctl <pct>|' /etc/systemd/system/fanctl.service
       systemctl enable --now fanctl.service

     temperature curve (needs TrueNAS):
       apt install -y python3-websocket
       fanctld init
       $EDITOR /etc/fanctld.conf      # paste the API key
       fanctld dry-run
       systemctl enable --now fanctld.service

NEXT
