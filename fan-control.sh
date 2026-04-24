#!/bin/bash
#
# /usr/local/sbin/fan-control.sh
#
# Dynamic fan control daemon for Zettlab D6U / D8U systems running
# TrueNAS SCALE or other Linux systems with hwmon support.
#
# --------------------------------------------------------------------
# USAGE
# --------------------------------------------------------------------
#
# Intended to run as a systemd service:
#
#     /usr/local/sbin/fan-control.sh
#
# Supported runtime flags:
#
#   --dry-run        Do not write PWM values (observe logic only)
#   --dry-run-log    Log calculated PWM values without applying them
#   --debug          Enable additional debug logging
#   --print-config   Print effective configuration and exit
#   --self-test      Run internal helper-function tests and exit
#
# --------------------------------------------------------------------
# DISCLAIMER
# --------------------------------------------------------------------
#
# This script directly controls hardware fan speeds.
# Use at your own risk.
# Always verify minimum safe fan speeds and thermal behavior
# for your specific hardware.
#
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail

########################################
#           CONFIG SOURCE               #
########################################

# Config file can be overridden by systemd Environment=
CONFIG_FILE="${CONFIG_FILE:-/etc/fan-control}"

########################################
#              DEFAULTS                #
########################################

# ---------- CPU temperature source ----------
# package = CPU package / Tctl if available
# hottest = hottest CPU sensor
CPU_TEMP_SOURCE="hottest"

# ---------- Logging thresholds ----------
CPU_TEMP_SPIKE_LOG=5
HDD_TEMP_SPIKE_LOG=2

# ---------- CPU ----------
TARGET_CPU_C=48
CPU_TEMP_BIAS_C=6
CPU_MIN_PWM=65
CPU_MAX_PWM=183
CPU_MAX_SAFE_TEMP_C=88
CPU_GAIN_TENTHS=32
CPU_RISE_EMA=25
CPU_FALL_EMA=8
CPU_PWM_OUT="pwm3"

# ---------- HDD ----------
TARGET_HDD_C=39
HDD_TEMP_BIAS_C=3
HDD_MIN_PWM=60
HDD_MAX_PWM=170
HDD_FALLBACK_PWM=145
HDD_GAIN_TENTHS=45
HDD_RISE_EMA=35
HDD_FALL_EMA=10
HDD_PWM_OUTS=("pwm1" "pwm2")

# ---------- General ----------
SLEEP_SECS=10

########################################
#           CLI FLAGS                  #
########################################

DEBUG=false
RUN_ONCE=false
DRY_RUN=false
DRY_RUN_LOG=false
PRINT_CONFIG=false
RUN_TESTS=false

log()  { echo "[INFO ] $*"; }
warn() { echo "[WARN ] $*" >&2; }

debug() {
  if $DEBUG; then
    echo "[DEBUG] $*"
  fi
}

dry_log() {
  if $DRY_RUN_LOG; then
    log "[DRY] $*"
  fi
}

for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG=true ;;
    --once) RUN_ONCE=true ;;
    --dry-run) DRY_RUN=true ;;
    --dry-run-log) DRY_RUN_LOG=true ;;
    --print-config) PRINT_CONFIG=true ;;
    --self-test) RUN_TESTS=true ;;
    *) warn "Unknown option: $arg" ;;
  esac
done

########################################
#        CONFIG LOAD / RELOAD           #
########################################

RELOAD_CONFIG=false

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/etc/fan-control
    source "$CONFIG_FILE"
    log "Configuration loaded from $CONFIG_FILE"
  else
    log "Config file $CONFIG_FILE not present; using defaults"
  fi
}

on_reload() {
  RELOAD_CONFIG=true
}

trap on_reload HUP

# Initial load
load_config

if $PRINT_CONFIG; then
  cat <<EOF
Effective configuration:
CPU_TEMP_SOURCE=$CPU_TEMP_SOURCE
TARGET_CPU_C=$TARGET_CPU_C
CPU_TEMP_BIAS_C=$CPU_TEMP_BIAS_C
TARGET_HDD_C=$TARGET_HDD_C
HDD_TEMP_BIAS_C=$HDD_TEMP_BIAS_C
SLEEP_SECS=$SLEEP_SECS
EOF
  exit 0
fi

########################################
#           HWMON DISCOVERY             #
########################################

find_hwmon_by_name() {
  local t="$1" d name
  for d in /sys/class/hwmon/hwmon*; do
    [[ -f "$d/name" ]] || continue
    IFS= read -r name <"$d/name" || continue
    [[ "$name" == "$t" ]] && printf '%s\n' "$d" && return 0
  done
  return 1
}

# Wait for hwmon during boot
for _ in {1..10}; do
  ls /sys/class/hwmon/hwmon* >/dev/null 2>&1 && break
  sleep 1
done

if ! ZETTLAB_HWMON=$(find_hwmon_by_name "zettlab_d8_fans"); then
  warn "zettlab_d8_fans hwmon not found"
  exit 1
fi

if ! CPU_HWMON=$(find_hwmon_by_name "coretemp"); then
  warn "coretemp hwmon not found"
  exit 1
fi

########################################
#              SENSORS                 #
########################################

mapfile -t DRIVES < <(
  lsblk -ndo TYPE,NAME | awk '$1=="disk" && $2 !~ /^nvme/ {print "/dev/"$2}'
)

read_cpu_temp() {
  local f label t max_t=0 max_label=""

  if [[ "$CPU_TEMP_SOURCE" == "package" ]]; then
    for f in "$CPU_HWMON"/temp*_input; do
      label="${f%_input}_label"
      [[ -f "$label" ]] || continue
      if grep -qiE 'package|tctl|tdie' "$label"; then
        printf '%d %s\n' "$(( $(<"$f") / 1000 ))" "$(tr -d ' ' <"$label")"
        return
      fi
    done
  fi

  for f in "$CPU_HWMON"/temp*_input; do
    label="${f%_input}_label"
    [[ -f "$label" ]] || continue
    t=$(( $(<"$f") / 1000 ))
    (( t > max_t )) && max_t=$t && max_label="$(tr -d ' ' <"$label")"
  done

  printf '%d %s\n' "$max_t" "$max_label"
}

read_drive_temp() {
  smartctl -A "$1" 2>/dev/null | awk '
    $1==190 || $1==194 {
      if (match($10, /^[0-9]+/)) {
        print substr($10, RSTART, RLENGTH)
        exit
      }
    }
  '
}

read_max_hdd_temp() {
  local t max=-1 disk hottest=""
  for disk in "${DRIVES[@]}"; do
    t=$(read_drive_temp "$disk") || continue
    (( t < 10 || t > 90 )) && continue
    (( t > max )) && max=$t && hottest="$disk"
  done
  (( max >= 0 )) && printf '%s %d\n' "$hottest" "$max"
}

########################################
#            CONTROL HELPERS            #
########################################

ema_step() {
  local last="$1" raw="$2" rise="$3" fall="$4"
  if (( raw > last )); then
    printf '%d\n' $(( last + (raw-last)*rise/100 ))
  else
    printf '%d\n' $(( last + (raw-last)*fall/100 ))
  fi
}

calc_pwm() {
  local temp="$1" target="$2" gain="$3" min="$4" max="$5"
  local delta pwm
  delta=$(( temp - target ))
  pwm=$(( min + delta * gain / 10 ))
  (( pwm < min )) && pwm=$min
  (( pwm > max )) && pwm=$max
  printf '%d\n' "$pwm"
}

########################################
#              MAIN LOOP                #
########################################

last_cpu=0
last_hdd=0
cpu_ema=0
hdd_ema=0

while true; do

  # Apply reload safely in-loop
  if $RELOAD_CONFIG; then
    load_config
    RELOAD_CONFIG=false
  fi

  ##### CPU #####
  if read -r raw_cpu cpu_label < <(read_cpu_temp); then
    eff_cpu=$(( raw_cpu + CPU_TEMP_BIAS_C ))

    if (( cpu_ema == 0 )); then
      cpu_ema="$eff_cpu"
    else
      cpu_ema=$(ema_step "$cpu_ema" "$eff_cpu" "$CPU_RISE_EMA" "$CPU_FALL_EMA")
    fi

    if (( eff_cpu >= CPU_MAX_SAFE_TEMP_C )); then
      cpu_pwm="$CPU_MAX_PWM"
    else
      cpu_pwm=$(calc_pwm "$cpu_ema" "$TARGET_CPU_C" "$CPU_GAIN_TENTHS" "$CPU_MIN_PWM" "$CPU_MAX_PWM")
    fi

    dry_log "CPU raw=${raw_cpu}C eff=${eff_cpu}C ema=${cpu_ema} pwm=${cpu_pwm} hottest=${cpu_label:-unknown}"
    $DRY_RUN || printf '%d\n' "$cpu_pwm" >"$ZETTLAB_HWMON/$CPU_PWM_OUT"

    last_cpu="$eff_cpu"
  fi

  ##### HDD #####
  if read -r disk raw_hdd < <(read_max_hdd_temp); then
    eff_hdd=$(( raw_hdd + HDD_TEMP_BIAS_C ))

    if (( hdd_ema == 0 )); then
      hdd_ema="$eff_hdd"
    else
      hdd_ema=$(ema_step "$hdd_ema" "$eff_hdd" "$HDD_RISE_EMA" "$HDD_FALL_EMA")
    fi

    hdd_pwm=$(calc_pwm "$hdd_ema" "$TARGET_HDD_C" "$HDD_GAIN_TENTHS" "$HDD_MIN_PWM" "$HDD_MAX_PWM")
    dry_log "HDD raw=${raw_hdd}C eff=${eff_hdd}C ema=${hdd_ema} pwm=${hdd_pwm} hottest=${disk##*/}"

    for o in "${HDD_PWM_OUTS[@]}"; do
      $DRY_RUN || printf '%d\n' "$hdd_pwm" >"$ZETTLAB_HWMON/$o"
    done
    last_hdd="$eff_hdd"
  else
    warn "HDD temps unavailable → forcing fallback PWM $HDD_FALLBACK_PWM"
    for o in "${HDD_PWM_OUTS[@]}"; do
      $DRY_RUN || printf '%d\n' "$HDD_FALLBACK_PWM" >"$ZETTLAB_HWMON/$o"
    done
  fi

  sleep "$SLEEP_SECS"
  $RUN_ONCE && break
done
