#!/usr/bin/env bash
# fanctl - one-shot installer for Proxmox VE
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/frangeris/fanctl/main/fanctl-install.sh)"
#
# Case fan control for boards whose ITE Super I/O has no upstream driver.
# Builds the out-of-tree it87 module, installs fanctl/fanctld and a
# systemd unit. `fanctl pwm` finds which PWM channel drives the header,
# during the install or any time after it.
#
# Run it again on an installed host to reconfigure or remove it:
#
#   bash -c "$(curl -fsSL .../fanctl-install.sh)" -- --uninstall
#
# Non-interactive overrides:
#   FANCTL_UNINSTALL=1    remove everything, no prompts
#   FANCTL_PWM=2          skip channel detection
#   FANCTL_FORCE_ID=0x8686
#   FANCTL_SPEED=40       fixed speed, skips the mode prompt
#
# License: MIT

set -euo pipefail

FORCE_ID="${FANCTL_FORCE_ID:-0x8686}"
MODPROBE_ARGS="force_id=${FORCE_ID} ignore_resource_conflict=1"
SRC_DIR=/usr/src/it87-fanctl
CAL_PATH=/etc/fanctl.max
PWM_PATH=/etc/fanctl.pwm
CONF_PATH=/etc/fanctld.conf
HWMON=""
PWM_CHANNEL="${FANCTL_PWM:-}"

RD=$'\033[01;31m'; GN=$'\033[1;92m'; YW=$'\033[33m'; BL=$'\033[36m'; CL=$'\033[m'
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${BL}»${CL}"

msg()      { echo -e " ${INFO} $1"; }
ok()       { echo -e " ${CM} $1"; }
warn()     { echo -e " ${YW}!${CL} $1"; }
fail()     { echo -e " ${CROSS} ${RD}$1${CL}" >&2; exit 1; }
die()      { gui_error "$1"; fail "$1"; }
header()   { echo -e "\n${BL}── $1 ──${CL}"; }

# ------------------------------------------------------------------
# dialogs
#
# whiptail draws the boxes the Proxmox helper scripts use. It renders
# with terminal characters, so it works the same over SSH and in the
# node Shell. When it is missing, or stdin is not a terminal, every
# wrapper falls back to plain prompts.
# ------------------------------------------------------------------
GUI=0
[ -t 0 ] && command -v whiptail >/dev/null 2>&1 && GUI=1
TITLE="fanctl installer"

# Rows a box needs: the text wrapped at the box width, plus the frame
# and buttons. Keeps a short message from sitting in a mostly empty box.
box_h() {  # text, extra rows
    local line n=0
    while IFS= read -r line; do n=$(( n + ${#line} / 68 + 1 )); done <<< "$1"
    echo $(( n + $2 ))
}

gui_msg() {  # title, text
    if [ "$GUI" = 1 ]; then
        whiptail --title "$TITLE" --backtitle "$1" --msgbox "$2" "$(box_h "$2" 6)" 74
    else
        header "$1"; echo "$2"
    fi
}

gui_yesno() {  # title, text -> 0 yes / 1 no
    if [ "$GUI" = 1 ]; then
        whiptail --title "$TITLE" --backtitle "$1" --yesno "$2" "$(box_h "$2" 6)" 74
    else
        header "$1"; echo "$2"
        local a; read -rp " [y/N] " a </dev/tty; [[ "${a,,}" == "y" ]]
    fi
}

gui_input() {  # title, prompt, default -> value on stdout
    if [ "$GUI" = 1 ]; then
        whiptail --title "$TITLE" --backtitle "$1" \
                 --inputbox "$2" 10 74 "$3" 3>&1 1>&2 2>&3
    else
        local a; read -rp " $2 [$3]: " a </dev/tty; echo "${a:-$3}"
    fi
}

gui_password() {  # title, prompt -> value on stdout
    if [ "$GUI" = 1 ]; then
        whiptail --title "$TITLE" --backtitle "$1" \
                 --passwordbox "$2" 10 74 3>&1 1>&2 2>&3
    else
        local a; read -rsp " $2: " a </dev/tty; echo >&2; echo "$a"
    fi
}

gui_menu() {  # title, text, tag1, item1, tag2, item2 ... -> tag on stdout
    local t="$1" text="$2" n=$(( ($# - 2) / 2 )); shift 2
    if [ "$GUI" = 1 ]; then
        whiptail --title "$TITLE" --backtitle "$t" \
                 --menu "$text" $(( n + 10 )) 74 "$n" "$@" 3>&1 1>&2 2>&3
    else
        {
            header "$t"; echo "$text"
            while [ $# -gt 0 ]; do echo "  $1) $2"; shift 2; done
        } >&2
        local a; read -rp " Choose: " a </dev/tty; echo "$a"
    fi
}

gui_radio() {  # title, text, tag1, item1, tag2, item2 ... -> tag on stdout
    local t="$1" text="$2" n=$(( ($# - 2) / 2 )) on=ON args=(); shift 2
    if [ "$GUI" = 1 ]; then
        # The first entry starts marked, so Enter alone accepts it.
        while [ $# -gt 0 ]; do args+=("$1" "$2" "$on"); on=OFF; shift 2; done
        whiptail --title "$TITLE" --backtitle "$t" \
                 --radiolist "$text" $(( $(box_h "$text" 9) + n )) 74 "$n" \
                 "${args[@]}" 3>&1 1>&2 2>&3
    else
        gui_menu "$t" "$text" "$@"
    fi
}

gui_error() {  # text
    [ "$GUI" = 1 ] && whiptail --title "$TITLE" --msgbox "ERROR\n\n$1" "$(box_h "$1" 8)" 74 || true
}

trap 'die "failed at line $LINENO"' ERR

# ------------------------------------------------------------------
# uninstall
# ------------------------------------------------------------------
do_uninstall() {
    header "Uninstall"

    [ "${FANCTL_UNINSTALL:-}" = "1" ] || gui_yesno "Uninstall" \
"Removes fanctl, fanctld, their systemd units, the config and
calibration, the it87 module settings, and the DKMS module if
this script built it.

Remove all of it?" || exit 0

    msg "stopping services"
    systemctl disable -q --now fanctld.service 2>/dev/null || true
    systemctl disable -q --now fanctl.service 2>/dev/null || true
    rm -f /etc/systemd/system/fanctl.service /etc/systemd/system/fanctld.service
    systemctl daemon-reload

    msg "removing files"
    rm -f /usr/local/bin/fanctl /usr/local/bin/fanctld "$CAL_PATH" "$PWM_PATH" "$CONF_PATH"
    rm -f /etc/modprobe.d/it87.conf
    sed -i '/^it87$/d' /etc/modules 2>/dev/null || true

    msg "unloading the module"
    modprobe -r it87 2>/dev/null || warn "it87 busy - gone after a reboot"

    if command -v dkms >/dev/null 2>&1; then
        ver=$(dkms status it87 2>/dev/null | head -1 | sed 's/[,/]/ /g' | awk '{print $2}')
        [ -n "${ver:-}" ] && { msg "removing DKMS it87/$ver"
                               dkms remove "it87/$ver" --all >/dev/null 2>&1 || true; }
    fi
    rm -rf "$SRC_DIR"
    ok "removed"

    gui_msg "Uninstall" \
"Done. One thing left:

  M.I.T. -> PC Health Status -> Smart Fan 5
    -> SYS_FAN -> Normal

The header was left in Full Speed for the OS to own. With nothing
driving it now, the fans sit at 100% until the BIOS takes the
curve back.

Any TrueNAS API key is gone from this host, but still exists on
TrueNAS - revoke it there if nothing else uses it."

    warn "set the BIOS back to Normal, or the fans stay at 100%"
    exit 0
}

[ "${1:-}" = "--uninstall" ] && do_uninstall
[ "${FANCTL_UNINSTALL:-}" = "1" ] && do_uninstall

# ------------------------------------------------------------------
# checks
# ------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root"
command -v pveversion >/dev/null 2>&1 || warn "pveversion not found - this is meant for a Proxmox host"

clear
cat <<'BANNER'

   __                 _   _
  / _| __ _ _ __   ___| |_| |
 | |_ / _` | '_ \ / __| __| |
 |  _| (_| | | | | (__| |_| |
 |_|  \__,_|_| |_|\___|\__|_|

 Case fan control for ITE Super I/O boards without an upstream driver

BANNER

if [ -x /usr/local/bin/fanctl ] || [ -f /etc/systemd/system/fanctld.service ]; then
    case "$(gui_menu "Already installed" \
        "fanctl is already on this host." \
        "1" "Reinstall - run setup from the start" \
        "2" "Uninstall - remove everything" \
        "3" "Cancel")" in
        2) do_uninstall ;;
        1) : ;;
        *) exit 0 ;;
    esac
fi

gui_yesno "Welcome" \
"Builds the it87 driver, finds the fan's PWM channel, measures
max RPM and sets a fixed speed or a TrueNAS temperature curve.

Continue?" || exit 0

# ------------------------------------------------------------------
gui_yesno "BIOS prerequisite" \
"The fans must be set to Full Speed in the BIOS.

Done?" \
  || fail "Set the fans to Full Speed in the BIOS, then run the installer again."

# ------------------------------------------------------------------
header "Dependencies"
msg "installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq dkms git build-essential lm-sensors python3-websocket \
    "proxmox-default-headers" >/dev/null 2>&1 \
  || apt-get install -y -qq dkms git build-essential lm-sensors python3-websocket \
       "pve-headers-$(uname -r)" >/dev/null
ok "dependencies installed"

# ------------------------------------------------------------------
header "it87 module"

load_module() { modprobe it87 ${MODPROBE_ARGS} 2>/dev/null; }

find_hwmon() {
    local p
    for p in /sys/class/hwmon/hwmon*; do
        [ -f "$p/name" ] || continue
        case "$(cat "$p/name")" in it86*|it87*) HWMON="$p"; return 0 ;; esac
    done
    return 1
}

if load_module && find_hwmon; then
    ok "in-tree module bound: $(cat "$HWMON/name")"
else
    msg "building the out-of-tree driver (frankcrawford/it87)"
    rm -rf "$SRC_DIR"
    git clone -q --depth 1 https://github.com/frankcrawford/it87 "$SRC_DIR"
    ( cd "$SRC_DIR" && make dkms >/dev/null 2>&1 ) || die "dkms build failed - check /var/lib/dkms"
    modprobe -r it87 2>/dev/null || true
    load_module || die "module will not load. If dmesg shows an ACPI resource conflict, add acpi_enforce_resources=lax to GRUB and reboot."
    find_hwmon || die "module loaded but no hwmon appeared"
    ok "built and loaded: $(cat "$HWMON/name")"
fi

msg "making it persistent"
echo "options it87 ${MODPROBE_ARGS}" > /etc/modprobe.d/it87.conf
grep -qx it87 /etc/modules 2>/dev/null || echo it87 >> /etc/modules
ok "/etc/modprobe.d/it87.conf and /etc/modules written"

# ------------------------------------------------------------------
header "Installing fanctl"

cat > /usr/local/bin/fanctl <<'FANCTL_EOF'
#!/bin/bash
# fanctl - manual case fan control (ITE Super I/O)
#
# Speed is expressed as a percentage of the fan's measured maximum RPM,
# not as PWM duty. Run `fanctl pwm` once to find the channel that drives
# the fans, then `fanctl calibrate` to record their maximum.

set -u

HWMON=""
for h in /sys/class/hwmon/hwmon*; do
    [ -f "$h/name" ] || continue
    case "$(cat "$h/name")" in
        it86*|it87*) HWMON="$h"; break ;;
    esac
done

if [ -z "$HWMON" ]; then
    echo "ERROR: it87 chip not found." >&2
    echo "Load it with: modprobe it87  (options in /etc/modprobe.d/it87.conf)" >&2
    exit 1
fi

PWM=""
PWM_PATH=/etc/fanctl.pwm
CAL=/etc/fanctl.max
CONF=/etc/fanctld.conf
STATE=/run/fanctld.state

read_rpm()  { cat "$HWMON/fan${PWM}_input" 2>/dev/null || echo 0; }
read_duty() { cat "$HWMON/pwm$PWM"; }

write_duty() {
    echo 1 > "$HWMON/pwm${PWM}_enable" 2>/dev/null
    if ! echo "$1" > "$HWMON/pwm$PWM" 2>/dev/null; then
        echo "ERROR: chip refused the write (header in automatic mode)." >&2
        echo "Set the fans to Full Speed in the BIOS." >&2
        exit 1
    fi
}

require_pwm() {
    if [ ! -s "$PWM_PATH" ]; then
        echo "No PWM channel set. Run first:  fanctl pwm" >&2
        exit 1
    fi
    PWM=$(cat "$PWM_PATH")
    if [ ! -f "$HWMON/pwm$PWM" ]; then
        echo "Bad channel in $PWM_PATH. Run: fanctl pwm" >&2
        exit 1
    fi
}

require_cal() {
    if [ ! -s "$CAL" ]; then
        echo "No calibration found. Run first:  fanctl calibrate" >&2
        exit 1
    fi
    MAX=$(cat "$CAL")
    if ! [ "$MAX" -gt 0 ] 2>/dev/null; then
        echo "Bad calibration in $CAL. Run: fanctl calibrate" >&2
        exit 1
    fi
}

bar() {
    local pct=$1 filled i out=""
    [ "$pct" -gt 100 ] && pct=100
    filled=$(( pct * 20 / 100 ))
    for ((i=0; i<20; i++)); do
        if [ "$i" -lt "$filled" ]; then out="${out}#"; else out="${out}."; fi
    done
    echo "$out"
}

cmd_calibrate() {
    local before peak=0 r i
    before=$(read_duty)
    echo "Running fan at 100% for 15s..."
    write_duty 255
    sleep 15
    for i in 1 2 3; do
        r=$(read_rpm)
        [ "$r" -gt "$peak" ] && peak=$r
        sleep 2
    done
    # Measuring is not a reason to leave the fans flat out.
    write_duty "$before"
    echo "$peak" > "$CAL"
    echo "Max speed: $peak RPM  (saved to $CAL)"
}

row() { printf "  %-11s %s\n" "$1" "$2"; }

# How the chip drives the channel. fanctl needs manual.
pwm_mode() {
    case "$(cat "$HWMON/pwm${PWM}_enable" 2>/dev/null)" in
        0) echo "full speed" ;;
        1) echo "manual" ;;
        "") echo "mode unknown" ;;
        *) echo "automatic (BIOS curve)" ;;
    esac
}

chip_info() {
    local opts
    opts=$(grep -o 'force_id=[^ ]*' /etc/modprobe.d/it87.conf 2>/dev/null)
    echo "$(cat "$HWMON/name")${opts:+, $opts}"
}

# Which unit drives the fans. Both at once fight over the channel.
fan_mode() {
    local fixed="" curve="" pct
    systemctl is-enabled -q fanctl.service 2>/dev/null && fixed=1
    systemctl is-enabled -q fanctld.service 2>/dev/null && curve=1
    if [ -n "$fixed" ] && [ -n "$curve" ]; then
        echo "CONFLICT - fanctl.service and fanctld.service are both enabled"
    elif [ -n "$curve" ]; then
        if systemctl is-active -q fanctld.service 2>/dev/null; then
            echo "TrueNAS curve - fanctld.service running"
        else
            echo "TrueNAS curve - fanctld.service NOT running"
        fi
    elif [ -n "$fixed" ]; then
        pct=$(sed -n 's|^ExecStart=.*fanctl \([0-9]*\).*|\1|p' \
              /etc/systemd/system/fanctl.service 2>/dev/null)
        echo "fixed ${pct:-?}% at boot - fanctl.service"
    else
        echo "manual - no service enabled"
    fi
}

# One key from the fanctld config, read the way fanctld reads it.
conf_get() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | tail -n1 |
        sed "s/[[:space:]]*\$//; s/^[\"']//; s/[\"']\$//"
}

state_get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null; }

ago() {
    local s=$1
    if [ "$s" -lt 120 ]; then echo "${s}s ago"
    elif [ "$s" -lt 7200 ]; then echo "$(( s / 60 ))m ago"
    else echo "$(( s / 3600 ))h ago"
    fi
}

# The disks from the last poll, hottest first, six to a row.
show_disks() {
    local d line="" n=0 label=disks
    for d in $(state_get disks); do
        line="$line${line:+   }${d%%:*} ${d#*:}C"
        n=$(( n + 1 ))
        if [ "$n" -eq 6 ]; then row "$label" "$line"; label=""; line=""; n=0; fi
    done
    [ -n "$line" ] && row "$label" "$line"
}

# The curve as temperature bands, like `fanctld curve`, marking the band
# the hottest disk is in.
show_curve() {  # points "0:35,36:45,...", hysteresis, hottest or ""
    local pts=(${1//,/ }) i low pct upper band mark
    echo "CURVE  hysteresis ${2}C"
    for (( i = 0; i < ${#pts[@]}; i++ )); do
        low=${pts[i]%%:*}; pct=${pts[i]#*:}; upper=""
        if [ $(( i + 1 )) -lt ${#pts[@]} ]; then
            upper=${pts[i+1]%%:*}; band="$low-$(( upper - 1 ))C"
        else
            band=">= ${low}C"
        fi
        mark=""
        if [ -n "$3" ] && [ "$3" -ge "$low" ] &&
           { [ -z "$upper" ] || [ "$3" -lt "$upper" ]; }; then
            mark="  <- ${3}C"
        fi
        printf "  %-11s %-5s [%s]%s\n" "$band" "$pct%" "$(bar "$pct")" "$mark"
    done
}

# The last poll fanctld left in $STATE.
show_reading() {  # poll interval
    local t out speed want
    t=$(state_get time)
    if [ -z "$t" ]; then
        if systemctl is-active -q fanctld.service 2>/dev/null; then
            row disks "waiting for the first poll"
        else
            row disks "no reading - fanctld is not running"
        fi
        return
    fi
    row polled "$(state_get at), $(ago $(( $(date +%s) - t ))) (every ${1}s)"
    out=$(state_get error)
    if [ -n "$out" ]; then
        row error "$out"
        if [ "$(state_get failsafe)" = 1 ]; then
            row "" "fans at 100% until TrueNAS answers ($(state_get failures) failed polls)"
        fi
        return
    fi
    show_disks
    speed=$(state_get speed); want=$(state_get curve)
    if [ -n "$want" ] && [ "$want" != "$speed" ]; then
        row hottest "$(state_get hottest)C -> ${want}%, held at ${speed}% by hysteresis"
    else
        row hottest "$(state_get hottest)C -> ${speed}%"
    fi
}

# The TrueNAS side: the config, and the daemon's last poll. Only the
# daemon talks to TrueNAS, so refreshing this costs it nothing.
show_truenas() {
    local out="" curve="" hyst="" poll
    echo "TRUENAS"
    if [ ! -e "$CONF" ]; then
        echo "  not set up"
        return
    fi
    if [ ! -r "$CONF" ]; then
        echo "  $CONF is readable by root only"
        return
    fi

    out=$(conf_get TRUENAS_HOST)
    row host "${out:-missing}"

    # fanctld knows the defaults and validates the curve, so ask it.
    if command -v fanctld >/dev/null; then
        out=$(fanctld curve 2>&1)
        curve=$(sed -n 's/^CURVE=//p' <<< "$out")
        hyst=$(sed -n 's/^HYSTERESIS=//p' <<< "$out")
    else
        out="fanctld is not installed"
    fi
    [ -n "$curve" ] || row error "$(tail -n1 <<< "$out")"

    # The unit's interval overrides POLL in the config.
    poll=$(sed -n 's|^ExecStart=.*fanctld daemon \([0-9][0-9]*\).*|\1|p' \
           /etc/systemd/system/fanctld.service 2>/dev/null)
    [ -n "$poll" ] || poll=$(conf_get POLL)
    show_reading "${poll:-60}"

    if [ -n "$curve" ]; then
        echo
        show_curve "$curve" "$hyst" "$(state_get hottest)"
    fi
}

# Everything that is set up, and what is still missing.
cmd_status() {
    local p max rpm spct
    p=$(cat "$PWM_PATH" 2>/dev/null)
    max=$(cat "$CAL" 2>/dev/null)

    echo "FAN"
    if [ -n "$p" ] && [ -f "$HWMON/pwm$p" ]; then
        PWM=$p
        rpm=$(read_rpm)
        if [ "${max:-0}" -gt 0 ] 2>/dev/null; then
            spct=$(( rpm * 100 / max ))
            row speed "${spct}%  [$(bar "$spct")]"
            row rpm "$rpm of $max max"
        else
            row rpm "$rpm, max not measured - run: fanctl calibrate"
        fi
        row duty "$(read_duty)/255"
        row channel "pwm$PWM, $(pwm_mode)"
    else
        row channel "not set - run: fanctl pwm"
    fi
    row chip "$(chip_info)"
    row mode "$(fan_mode)"
    echo
    show_truenas
}

cmd_set() {
    require_cal
    local want=$1 target duty rpm i best_d best_err err
    [ "$want" -lt 0 ] && want=0
    [ "$want" -gt 100 ] && want=100

    if [ "$want" -eq 0 ]; then
        write_duty 0
        echo "fan -> stopped"
        return
    fi
    if [ "$want" -eq 100 ]; then
        write_duty 255
        echo "fan -> 100% speed (~${MAX} RPM)"
        return
    fi

    target=$(( MAX * want / 100 ))
    duty=$(( 255 * want / 100 ))
    best_d=$duty; best_err=999999

    for i in $(seq 1 10); do
        write_duty "$duty"
        sleep 4
        rpm=$(read_rpm)
        err=$(( rpm - target )); [ "$err" -lt 0 ] && err=$(( -err ))
        if [ "$err" -lt "$best_err" ]; then best_err=$err; best_d=$duty; fi
        [ "$err" -le $(( target / 33 + 10 )) ] && break
        if [ "$rpm" -gt "$target" ]; then
            duty=$(( duty - (rpm - target) * 255 / MAX / 2 - 1 ))
        else
            duty=$(( duty + (target - rpm) * 255 / MAX / 2 + 1 ))
        fi
        [ "$duty" -lt 1 ] && duty=1
        [ "$duty" -gt 255 ] && duty=255
    done

    write_duty "$best_d"
    sleep 3
    rpm=$(read_rpm)
    echo "fan -> ${want}% speed | target ${target} RPM | actual ${rpm} RPM | duty ${best_d}/255"
}

# status refreshes until Ctrl-C. Piped or scripted, it prints once.
cmd_live() {
    local interval=$1 out
    if [ "$interval" = "--once" ] || [ ! -t 1 ]; then
        cmd_status
        return
    fi
    trap 'echo; exit 0' INT
    while true; do
        # Build the screen first, so it does not flicker while fanctld runs.
        out=$(cmd_status)
        clear
        echo "$(date '+%H:%M:%S')  every ${interval}s, Ctrl-C to quit"; echo
        echo "$out"
        sleep "$interval"
    done
}

ask() {
    local a
    read -rp "$1 [y/N] " a </dev/tty
    [[ "${a,,}" == y* ]]
}

save_pwm() {
    local p=$1 old
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ ! -f "$HWMON/pwm$p" ]; then
        echo "No pwm$p on this chip." >&2
        exit 1
    fi
    old=$(cat "$PWM_PATH" 2>/dev/null)
    echo "$p" > "$PWM_PATH"
    if [ "$old" = "$p" ]; then
        echo "Channel: pwm$p (unchanged)"
        return
    fi
    # A maximum measured on another channel's tachometer is meaningless.
    rm -f "$CAL"
    echo "Channel: pwm$p  (saved to $PWM_PATH)"
    echo "Next:    fanctl calibrate"
}

# With a forced chip ID the channel numbers do not match the silkscreen,
# and a tachometer can track its own PWM register without any real fan
# behind it. The only reliable test is watching the blades.
cmd_pwm() {
    if [ -n "${1:-}" ]; then
        save_pwm "$1"
        return
    fi

    if systemctl is-active -q fanctld.service 2>/dev/null; then
        echo "Stopping fanctld while testing. Start it again when done."
        systemctl stop fanctld.service
    fi

    echo "Open the case and watch the fans."
    echo "Each channel runs 5s fast, then 5s slow."

    local f p found=""
    for f in "$HWMON"/pwm[0-9]; do
        p=${f##*pwm}
        echo; echo "=== pwm$p ==="
        echo 1 > "$HWMON/pwm${p}_enable" 2>/dev/null
        if ! echo 255 > "$f" 2>/dev/null; then
            echo "pwm$p refuses writes - skipping"
            continue
        fi
        sleep 5
        echo 30 > "$f"
        sleep 5
        if ask "Did the fans slow down?"; then
            echo 255 > "$f"
            found=$p
            break
        fi
        echo 255 > "$f"
    done

    if [ -z "$found" ]; then
        echo "No channel moved the fans. Check they are on a PWM header" >&2
        echo "and set to Full Speed in the BIOS." >&2
        exit 1
    fi

    # A hasty yes on the channel whose reading moves but whose fans do
    # not would poison the calibration, so test it once more.
    echo 30 > "$HWMON/pwm$found"
    sleep 6
    if ! ask "pwm$found is at 30/255 now. Are the fans clearly slower?"; then
        echo 255 > "$HWMON/pwm$found"
        echo "Not confirmed. Run fanctl pwm again, or set it: fanctl pwm <n>" >&2
        exit 1
    fi
    echo 255 > "$HWMON/pwm$found"
    save_pwm "$found"
}

usage() {
    cat <<EOF
fanctl - case fans, controlled by SPEED percentage

  fanctl pwm         Find the channel that drives the fans (run once)
  fanctl pwm <n>     Set the channel directly
  fanctl calibrate   Measure max RPM (run once)
  fanctl <pct>       Set speed to <pct>% of max RPM
  fanctl status [s]  Live view of speed, channel, mode and TrueNAS setup,
                     every s seconds (default 2). --once prints it once.
  fanctl max         100%

  fanctl 60          -> 60% of max RPM
EOF
}

case "${1:-}" in
    pwm)          cmd_pwm "${2:-}" ;;
    calibrate)    require_pwm; cmd_calibrate ;;
    status|watch) cmd_live "${2:-2}" ;;
    max)          require_pwm; cmd_set 100 ;;
    [0-9]*)       require_pwm; cmd_set "$1" ;;
    *)            usage ;;
esac
FANCTL_EOF

chmod +x /usr/local/bin/fanctl
ok "/usr/local/bin/fanctl"

# ------------------------------------------------------------------
header "PWM channel"
# On a rerun a running unit would fight the channel test and the
# calibration, and enable --now would leave it running the old settings.
systemctl stop fanctld.service fanctl.service 2>/dev/null || true

if [ -n "$PWM_CHANNEL" ]; then
    /usr/local/bin/fanctl pwm "$PWM_CHANNEL" >/dev/null \
      || die "no pwm${PWM_CHANNEL} on this chip (FANCTL_PWM)"
elif [ -s "$PWM_PATH" ]; then
    :   # set by an earlier run; change it with fanctl pwm
else
    # Channel numbers need not match the board labels, and a reading can
    # move without any fan behind it, so a pick from the list is for
    # someone who already knows. Everyone else should detect.
    opts=("detect" "Test each channel while you watch the fans")
    for f in "$HWMON"/pwm[0-9]; do
        p=${f##*pwm}
        opts+=("pwm$p" "reads $(cat "$HWMON/fan${p}_input" 2>/dev/null || echo "?") RPM")
    done
    opts+=("later" "Set it later with: fanctl pwm")

    choice=$(gui_radio "PWM channel" "Which channel drives the fans?
Space marks one, Enter confirms." "${opts[@]}") || choice=later
    case "$choice" in
        detect) /usr/local/bin/fanctl pwm || warn "no channel set - run fanctl pwm later" ;;
        pwm*)   /usr/local/bin/fanctl pwm "${choice#pwm}" >/dev/null \
                  || warn "no ${choice} on this chip - run fanctl pwm later" ;;
    esac
fi
PWM_CHANNEL=$(cat "$PWM_PATH" 2>/dev/null || true)

if [ -z "$PWM_CHANNEL" ]; then
    header "Done"
    cat <<NEXT
 fanctl is installed, but it does not know which channel drives the
 fans yet. Next:

   fanctl pwm          find the channel
   fanctl calibrate    measure max RPM

 Then run this installer again to pick a fixed speed or the TrueNAS curve.

NEXT
    exit 0
fi
ok "channel: pwm${PWM_CHANNEL}"

# ------------------------------------------------------------------
header "Calibration"
msg "measuring maximum RPM (about 20s)"
/usr/local/bin/fanctl calibrate
MAX_RPM=$(cat "$CAL_PATH")
[ "$MAX_RPM" -gt 100 ] || warn "suspiciously low maximum (${MAX_RPM} RPM) - the tachometer may not be reading this fan"

# ------------------------------------------------------------------
header "Mode"
MODE=fixed
SPEED="${FANCTL_SPEED:-}"
if [ -z "$SPEED" ]; then
    m=$(gui_menu "Mode" "How should the fans be driven?" \
        "1" "Fixed speed - one value, applied at boot" \
        "2" "TrueNAS curve - follows HDD temperatures")
    [ "$m" = "2" ] && MODE=curve
fi

if [ "$MODE" = fixed ]; then
    [ -n "$SPEED" ] || SPEED=$(gui_input "Fixed speed" \
        "Fan speed, as a percentage of the measured maximum RPM:" "40")
    SPEED="${SPEED:-40}"
    cat > /etc/systemd/system/fanctl.service <<UNIT
[Unit]
Description=Case fan speed (fixed)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fanctl ${SPEED}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl disable -q fanctld.service 2>/dev/null || true
    systemctl enable -q --now fanctl.service
    ok "fanctl.service enabled at ${SPEED}%"
else
    TN_HOST=$(gui_input "TrueNAS curve" "TrueNAS address:" "192.168.1.121")
    TN_KEY=$(gui_password "TrueNAS curve" \
        "API key (TrueNAS avatar -> API Keys, Readonly Admin role):")
    [ -n "$TN_HOST" ] && [ -n "$TN_KEY" ] || die "address and API key are both required"

    msg "installing fanctld"
    cat > /usr/local/bin/fanctld <<'FANCTLD_EOF'
#!/usr/bin/env python3
"""fanctld - fan curve driven by TrueNAS disk temperatures.

Reads disk temps from TrueNAS over JSON-RPC 2.0 (WebSocket) and writes
the PWM duty on the Proxmox host. Fails safe to 100% when TrueNAS is
unreachable.

Config: /etc/fanctld.conf  (mode 600)
State:  /run/fanctld.state  (last poll, shown by `fanctl status`)

    TRUENAS_HOST=192.168.1.121
    TRUENAS_KEY=<api key>
    CURVE=0:35,36:45,40:55,43:70,46:85,50:100
    HYSTERESIS=2
    POLL=60

CURVE is a comma-separated list of `temp:speed` points, where speed is a
percentage of the fan's measured maximum RPM. The hottest disk picks the
point: at or above 46 C in the example above, the fans run at 85%. The
first point must be 0, so there is always a floor.

HYSTERESIS keeps the fans from oscillating at a boundary: once a step is
taken, the temperature has to fall that many degrees below the edge
before stepping back down.
"""

import glob
import json
import os
import ssl
import sys
import time
import signal
import argparse
import logging

try:
    import websocket
except ImportError:
    sys.exit("Missing python3-websocket.  apt install -y python3-websocket")

CONF_PATH = "/etc/fanctld.conf"
CAL_PATH = "/etc/fanctl.max"
PWM_PATH = "/etc/fanctl.pwm"
STATE_PATH = "/run/fanctld.state"
PWM_MAX = 255

DEFAULT_CURVE = [(0, 35), (36, 45), (40, 55), (43, 70), (46, 85), (50, 100)]
DEFAULT_HYSTERESIS = 2
DEFAULT_POLL = 60

FAIL_LIMIT = 3           # consecutive failures before forcing 100%

log = logging.getLogger("fanctld")


# --------------------------------------------------------------------
# host side
# --------------------------------------------------------------------

def find_hwmon():
    for path in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            with open(os.path.join(path, "name")) as f:
                if f.read().strip().startswith(("it86", "it87")):
                    return path
        except OSError:
            continue
    sys.exit("it87 chip not found. modprobe it87 "
             "(options in /etc/modprobe.d/it87.conf)")


class Fan:
    def __init__(self, hwmon):
        self.channel = self._load_channel(hwmon)
        self.pwm = os.path.join(hwmon, f"pwm{self.channel}")
        self.enable = os.path.join(hwmon, f"pwm{self.channel}_enable")
        self.tach = os.path.join(hwmon, f"fan{self.channel}_input")
        self.max_rpm = self._load_calibration()

    @staticmethod
    def _load_channel(hwmon):
        try:
            with open(PWM_PATH) as f:
                value = int(f.read().strip())
            if os.path.exists(os.path.join(hwmon, f"pwm{value}")):
                return value
        except (OSError, ValueError):
            pass
        sys.exit(f"No PWM channel in {PWM_PATH}. Run: fanctl pwm")

    @staticmethod
    def _load_calibration():
        try:
            with open(CAL_PATH) as f:
                value = int(f.read().strip())
            if value > 0:
                return value
        except (OSError, ValueError):
            pass
        sys.exit(f"No calibration in {CAL_PATH}. Run: fanctl calibrate")

    def set_duty(self, duty):
        duty = max(0, min(PWM_MAX, int(duty)))
        try:
            with open(self.enable, "w") as f:
                f.write("1")
        except OSError:
            pass
        try:
            with open(self.pwm, "w") as f:
                f.write(str(duty))
        except OSError as exc:
            log.error("cannot write %s: %s", self.pwm, exc)
            raise
        return duty

    def read_duty(self):
        with open(self.pwm) as f:
            return int(f.read().strip())

    def read_rpm(self):
        try:
            with open(self.tach) as f:
                return int(f.read().strip())
        except OSError:
            return 0

    def set_speed_pct(self, pct, settle=4, tries=8):
        """Closed loop: aim for pct% of max RPM, return (duty, rpm)."""
        if pct >= 100:
            return self.set_duty(PWM_MAX), self.read_rpm()

        target = self.max_rpm * pct // 100
        duty = PWM_MAX * pct // 100
        best_duty, best_err = duty, None

        for _ in range(tries):
            self.set_duty(duty)
            time.sleep(settle)
            rpm = self.read_rpm()
            err = abs(rpm - target)
            if best_err is None or err < best_err:
                best_err, best_duty = err, duty
            if err <= max(target // 33, 25):
                break
            step = (target - rpm) * PWM_MAX // self.max_rpm // 2
            duty = max(1, min(PWM_MAX, duty + step + (1 if step >= 0 else -1)))

        self.set_duty(best_duty)
        time.sleep(2)
        return best_duty, self.read_rpm()


# --------------------------------------------------------------------
# TrueNAS side
# --------------------------------------------------------------------

class TrueNAS:
    def __init__(self, host, key, timeout=10):
        self.url = f"wss://{host}/api/current"
        self.key = key
        self.timeout = timeout
        self.ws = None
        self.msg_id = 0

    def __enter__(self):
        self.ws = websocket.create_connection(
            self.url, timeout=self.timeout,
            sslopt={"cert_reqs": ssl.CERT_NONE},
        )
        if not self._call("auth.login_with_api_key", [self.key]):
            raise RuntimeError("auth.login_with_api_key rejected")
        return self

    def __exit__(self, *exc):
        if self.ws:
            try:
                self.ws.close()
            except Exception:
                pass

    def _call(self, method, params=None):
        self.msg_id += 1
        self.ws.send(json.dumps({
            "jsonrpc": "2.0",
            "id": self.msg_id,
            "method": method,
            "params": params or [],
        }))
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            resp = json.loads(self.ws.recv())
            if resp.get("id") != self.msg_id:
                continue
            if "error" in resp:
                raise RuntimeError(resp["error"].get("message", resp["error"]))
            return resp.get("result")
        raise TimeoutError(f"no reply to {method}")

    def disk_temps(self):
        disks = self._call("disk.query", [[], {"select": ["name"]}])
        names = [d["name"] for d in disks if d.get("name", "").startswith("sd")]
        if not names:
            return {}
        temps = self._call("disk.temperatures", [names])
        return {k: v for k, v in temps.items() if isinstance(v, (int, float))}


# --------------------------------------------------------------------

def load_conf():
    if not os.path.exists(CONF_PATH):
        sys.exit(f"Missing {CONF_PATH}. Run: fanctld init")
    if os.stat(CONF_PATH).st_mode & 0o077:
        sys.exit(f"{CONF_PATH} is readable by others. chmod 600 {CONF_PATH}")
    conf = {}
    with open(CONF_PATH) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip().strip('"').strip("'")
    for key in ("TRUENAS_HOST", "TRUENAS_KEY"):
        if not conf.get(key):
            sys.exit(f"Missing {key} in {CONF_PATH}")

    try:
        conf["CURVE"] = (parse_curve(conf["CURVE"]) if conf.get("CURVE")
                         else list(DEFAULT_CURVE))
    except ValueError as exc:
        sys.exit(f"Bad CURVE in {CONF_PATH}: {exc}")

    for key, default in (("HYSTERESIS", DEFAULT_HYSTERESIS),
                         ("POLL", DEFAULT_POLL)):
        try:
            conf[key] = int(conf.get(key, default))
        except ValueError:
            sys.exit(f"{key} in {CONF_PATH} must be a whole number")
    if conf["HYSTERESIS"] < 0:
        sys.exit("HYSTERESIS must not be negative")
    if conf["POLL"] < 5:
        sys.exit("POLL must be at least 5 seconds")

    return conf


def write_conf_key(key, value):
    """Replace or append one key in the config, leaving the rest alone."""
    lines = []
    replaced = False
    with open(CONF_PATH) as f:
        for line in f:
            if line.strip().startswith(f"{key}="):
                lines.append(f"{key}={value}\n")
                replaced = True
            else:
                lines.append(line)
    if not replaced:
        if lines and not lines[-1].endswith("\n"):
            lines.append("\n")
        lines.append(f"{key}={value}\n")
    with open(CONF_PATH, "w") as f:
        f.writelines(lines)
    os.chmod(CONF_PATH, 0o600)


def parse_curve(text):
    """"0:35,40:55,50:100" -> [(0, 35), (40, 55), (50, 100)], validated."""
    points = []
    for chunk in text.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        if ":" not in chunk:
            raise ValueError(f"bad point {chunk!r}, expected temp:speed")
        temp_s, pct_s = chunk.split(":", 1)
        try:
            temp, pct = int(temp_s), int(pct_s)
        except ValueError:
            raise ValueError(f"bad point {chunk!r}, expected whole numbers")
        if not 0 <= pct <= 100:
            raise ValueError(f"speed {pct} out of range in {chunk!r}")
        if not 0 <= temp <= 100:
            raise ValueError(f"temperature {temp} out of range in {chunk!r}")
        points.append((temp, pct))

    if not points:
        raise ValueError("curve is empty")
    points.sort()
    if points[0][0] != 0:
        raise ValueError("the first point must be 0, so the curve has a floor")
    temps = [t for t, _ in points]
    if len(set(temps)) != len(temps):
        raise ValueError("duplicate temperature in the curve")
    speeds = [p for _, p in points]
    if speeds != sorted(speeds):
        raise ValueError("speeds must not decrease as temperature rises")
    return points


def format_curve(curve):
    return ",".join(f"{t}:{p}" for t, p in curve)


def bar(pct):
    filled = min(pct, 100) * 20 // 100
    return "[" + "#" * filled + "." * (20 - filled) + "]"


def curve_table(curve, hysteresis):
    """The curve as temperature bands, laid out like `fanctl status`."""
    lines = [f"CURVE  hysteresis {hysteresis}C"]
    for i, (low, pct) in enumerate(curve):
        upper = curve[i + 1][0] if i + 1 < len(curve) else None
        band = f"{low}-{upper - 1}C" if upper else f">= {low}C"
        lines.append(f"  {band:<11} {str(pct) + '%':<5} {bar(pct)}")
    return "\n".join(lines)


def lookup(temp, curve):
    speed = curve[0][1]
    for threshold, pct in curve:
        if temp >= threshold:
            speed = pct
    return speed


def speed_for_temp(temp, curve, current=None, hysteresis=DEFAULT_HYSTERESIS):
    """Curve lookup, refusing to step down until temp drops far enough.

    Without this a disk sitting on a boundary makes the fans step up and
    down every poll, which is more irritating than the extra noise.
    """
    want = lookup(temp, curve)
    if current is not None and want < current:
        if lookup(temp + hysteresis, curve) >= current:
            return current
    return want


def save_state(**fields):
    """Leave the last poll where `fanctl status` can read it.

    Only the daemon talks to TrueNAS; status refreshes every couple of
    seconds and must not add API calls of its own.
    """
    fields["time"] = int(time.time())
    fields["at"] = time.strftime("%H:%M:%S")
    tmp = STATE_PATH + ".tmp"
    try:
        with open(tmp, "w") as f:
            for key, value in fields.items():
                f.write(f"{key}={' '.join(str(value).split())}\n")
        os.replace(tmp, STATE_PATH)
    except OSError as exc:
        log.debug("cannot write %s: %s", STATE_PATH, exc)


def poll_temps(conf):
    with TrueNAS(conf["TRUENAS_HOST"], conf["TRUENAS_KEY"]) as nas:
        temps = nas.disk_temps()
    if not temps:
        raise RuntimeError("disk.temperatures returned nothing")
    return temps


def cmd_once(fan, conf, apply_change=True):
    temps = poll_temps(conf)
    hottest = max(temps.values())
    want = speed_for_temp(hottest, conf["CURVE"])
    if apply_change:
        duty, rpm = fan.set_speed_pct(want)
        log.info("hdd max %.0fC -> %d%% | duty %d/255 | %d RPM",
                 hottest, want, duty, rpm)
    else:
        log.info("hdd max %.0fC -> would set %d%%", hottest, want)
    return hottest, want


def cmd_daemon(fan, conf, interval=None):
    def bail(_sig, _frm):
        log.warning("shutting down - fans to 100%")
        fan.set_duty(PWM_MAX)
        try:
            os.remove(STATE_PATH)
        except OSError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGINT, bail)
    signal.signal(signal.SIGTERM, bail)

    interval = interval or conf["POLL"]
    curve, hyst = conf["CURVE"], conf["HYSTERESIS"]
    log.info("polling every %ds (channel pwm%d)", interval, fan.channel)
    log.info("curve %s, hysteresis %dC", format_curve(curve), hyst)
    failures = 0
    last_pct = None

    while True:
        started = time.monotonic()
        try:
            temps = poll_temps(conf)
            failures = 0
            hottest = max(temps.values())
            want = speed_for_temp(hottest, curve, last_pct, hyst)
            if want != last_pct:
                duty, rpm = fan.set_speed_pct(want)
                log.info("hdd max %.0fC -> %d%% | duty %d/255 | %d RPM",
                         hottest, want, duty, rpm)
                last_pct = want
            else:
                log.debug("hdd max %.0fC, holding %d%%", hottest, want)
            save_state(disks=" ".join(f"{name}:{temp:.0f}" for name, temp in
                                      sorted(temps.items(), key=lambda kv: -kv[1])),
                       hottest=f"{hottest:.0f}", speed=last_pct,
                       curve=lookup(hottest, curve))
        except Exception as exc:
            failures += 1
            if failures < FAIL_LIMIT:
                log.error("poll failed (%d/%d): %s", failures, FAIL_LIMIT, exc)
            else:
                log.error("poll failed (%d in a row, fans at 100%%): %s",
                          failures, exc)
            if failures >= FAIL_LIMIT:
                if last_pct != 100:
                    log.warning("TrueNAS unreachable - forcing 100%")
                    fan.set_duty(PWM_MAX)
                    last_pct = 100
            save_state(error=exc, failures=failures,
                       failsafe=int(failures >= FAIL_LIMIT))

        elapsed = time.monotonic() - started
        time.sleep(max(1.0, interval - elapsed))


def cmd_curve(conf, args):
    curve = conf["CURVE"]

    if not args:
        print(curve_table(curve, conf["HYSTERESIS"]))
        print(f"\nCURVE={format_curve(curve)}")
        print(f"HYSTERESIS={conf['HYSTERESIS']}")
        return

    action, rest = args[0], args[1:]

    if action == "set":
        if not rest:
            sys.exit('usage: fanctld curve set "0:35,40:55,50:100"')
        try:
            new = parse_curve(" ".join(rest))
        except ValueError as exc:
            sys.exit(f"Bad curve: {exc}")
        write_conf_key("CURVE", format_curve(new))
        print(curve_table(new, conf["HYSTERESIS"]))
        print(f"\nSaved to {CONF_PATH}.")
        print("Apply it with:  systemctl restart fanctld")
        return

    if action == "hysteresis":
        if not rest:
            sys.exit("usage: fanctld curve hysteresis <degrees>")
        try:
            value = int(rest[0])
        except ValueError:
            sys.exit("hysteresis must be a whole number of degrees")
        if value < 0:
            sys.exit("hysteresis must not be negative")
        write_conf_key("HYSTERESIS", value)
        print(f"HYSTERESIS={value}C saved to {CONF_PATH}.")
        print("Apply it with:  systemctl restart fanctld")
        return

    if action == "test":
        if not rest:
            sys.exit("usage: fanctld curve test <temperature>")
        try:
            temp = float(rest[0])
        except ValueError:
            sys.exit("temperature must be a number")
        plain = speed_for_temp(temp, curve)
        print(f"{temp:.0f}C -> {plain}%")
        if conf["HYSTERESIS"]:
            for current in sorted({p for _, p in curve}, reverse=True):
                held = speed_for_temp(temp, curve, current, conf["HYSTERESIS"])
                if held != plain:
                    print(f"  (holds at {held}% when already running "
                          f"at {current}%, hysteresis {conf['HYSTERESIS']}C)")
                    break
        return

    sys.exit(f"unknown curve action {action!r} - try: set, hysteresis, test")


def cmd_init():
    if os.path.exists(CONF_PATH):
        sys.exit(f"{CONF_PATH} already exists.")
    with open(CONF_PATH, "w") as f:
        f.write(
            "TRUENAS_HOST=192.168.1.121\n"
            "TRUENAS_KEY=\n"
            f"CURVE={format_curve(DEFAULT_CURVE)}\n"
            f"HYSTERESIS={DEFAULT_HYSTERESIS}\n"
            f"POLL={DEFAULT_POLL}\n"
        )
    os.chmod(CONF_PATH, 0o600)
    print(f"Created {CONF_PATH} (mode 600). Fill in TRUENAS_KEY.")


def main():
    ap = argparse.ArgumentParser(
        description="Fan curve from TrueNAS disk temperatures",
        epilog='examples:\n'
               '  fanctld dry-run\n'
               '  fanctld curve\n'
               '  fanctld curve set "0:30,38:45,42:60,46:80,50:100"\n'
               '  fanctld curve hysteresis 3\n'
               '  fanctld curve test 44\n',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command",
                    choices=["once", "dry-run", "daemon", "curve", "init"])
    ap.add_argument("args", nargs="*",
                    help="daemon: poll interval in seconds. "
                         "curve: set|hysteresis|test plus its argument.")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    if args.command == "init":
        return cmd_init()

    conf = load_conf()

    if args.command == "curve":
        return cmd_curve(conf, args.args)

    fan = Fan(find_hwmon())

    if args.command == "once":
        return cmd_once(fan, conf)
    if args.command == "dry-run":
        return cmd_once(fan, conf, apply_change=False)
    if args.command == "daemon":
        interval = int(args.args[0]) if args.args else None
        return cmd_daemon(fan, conf, interval)


if __name__ == "__main__":
    main()
FANCTLD_EOF
    chmod +x /usr/local/bin/fanctld

    printf 'TRUENAS_HOST=%s\nTRUENAS_KEY=%s\n' "$TN_HOST" "$TN_KEY" > "$CONF_PATH"
    chmod 600 "$CONF_PATH"

    msg "testing the connection"
    /usr/local/bin/fanctld dry-run || die "Cannot reach TrueNAS.

Check the address and the API key in ${CONF_PATH}, then run:
  fanctld dry-run"

    cat > /etc/systemd/system/fanctld.service <<'UNIT'
[Unit]
Description=Fan curve from TrueNAS disk temperatures
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/fanctld daemon 60
ExecStopPost=/usr/local/bin/fanctl 100
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl disable -q fanctl.service 2>/dev/null || true
    rm -f /run/fanctld.state
    systemctl enable -q --now fanctld.service
    ok "fanctld.service enabled"

    # The daemon sets the speed in the background. Until its first poll the
    # fans stay at 100%, and that is what the summary below would show.
    msg "waiting for the first reading from TrueNAS"
    for _ in $(seq 60); do [ -s /run/fanctld.state ] && break; sleep 1; done
fi

# ------------------------------------------------------------------
header "Done"
/usr/local/bin/fanctl status --once
cat <<SUMMARY

 fanctl 50          set 50% of max RPM
 fanctl status      live view
SUMMARY
[ "$MODE" = curve ] && echo " journalctl -u fanctld -f    follow the curve"
echo
warn "DKMS rebuilds it87 on kernel upgrades. If upstream ever lags a new"
warn "Proxmox kernel, fan control falls back to the BIOS curve - harmless,"
warn "but that is why the fans may sound different after an upgrade."
echo
