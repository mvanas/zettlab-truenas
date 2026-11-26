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
#   --once           Run a single control cycle and exit
#   --debug          Enable additional debug logging
#   --print-config   Print effective configuration and exit
#   --self-test      Run internal helper-function tests and exit
#                    (requires the fan driver to be loaded)
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
# Warn in the journal when the raw temperature jumps by this many
# degrees C or more between two consecutive polls.
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

# Consecutive failed CPU temperature reads tolerated before the
# controller forces CPU_MAX_PWM as a safety measure.
CPU_READ_FAIL_LIMIT=3

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

# Drive temperatures are read only every Nth control cycle. HDD
# temperatures change slowly, and every poll runs smartctl against
# every drive. At SLEEP_SECS=10, HDD_POLL_EVERY=6 means one SMART
# poll per drive every ~60 seconds.
HDD_POLL_EVERY=6

# Consecutive failed SMART polls (real errors, not standby drives)
# tolerated before HDD_FALLBACK_PWM is forced.
HDD_MISS_TOLERANCE=3

# Timeout per smartctl invocation. A hung or dying drive must never
# block the CPU control loop.
SMARTCTL_TIMEOUT_SECS=10

# ---------- PWM output shaping ----------
# The applied fan PWM follows the controller target with rate limits
# and a deadband, so fans do not change speed on every small
# temperature wobble (anti-hunting). Rise stays fast for safety;
# fall is intentionally slow and damped.
PWM_RISE_STEP=6     # max PWM increase per control cycle
PWM_FALL_STEP=2     # max PWM decrease per control cycle
PWM_DEADBAND=4      # ignore target changes smaller than this

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
CPU_READ_FAIL_LIMIT=$CPU_READ_FAIL_LIMIT
HDD_POLL_EVERY=$HDD_POLL_EVERY
HDD_MISS_TOLERANCE=$HDD_MISS_TOLERANCE
SMARTCTL_TIMEOUT_SECS=$SMARTCTL_TIMEOUT_SECS
PWM_RISE_STEP=$PWM_RISE_STEP
PWM_FALL_STEP=$PWM_FALL_STEP
PWM_DEADBAND=$PWM_DEADBAND
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

enumerate_drives() {
  # SATA/USB disks only; NVMe drives are cooled separately and do
  # not report SMART attributes 190/194.
  mapfile -t DRIVES < <(
    lsblk -ndo TYPE,NAME | awk '$1=="disk" && $2 !~ /^nvme/ {print "/dev/"$2}'
  )
}

enumerate_drives

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
  # -n standby: never wake a sleeping drive (smartctl exits with
  #   status 2 instead of querying the drive)
  # timeout:    a hung drive must never block the control loop
  timeout "$SMARTCTL_TIMEOUT_SECS" smartctl -A -n standby "$1" 2>/dev/null | awk '
    $1==190 || $1==194 {
      if (match($10, /^[0-9]+/)) {
        print substr($10, RSTART, RLENGTH)
        exit
      }
    }
  '
}

# Sets HDD_POLL_STATUS to "ok", "standby" or "error".
# Prints "<disk> <temp>" only when status is "ok".
read_max_hdd_temp() {
  local t max=-1 disk hottest="" rc=0 n_standby=0
  HDD_POLL_STATUS="error"
  for disk in "${DRIVES[@]}"; do
    t=$(read_drive_temp "$disk") && rc=0 || rc=$?
    if (( rc == 2 )); then
      # Drive is spun down; do not count this as a failure.
      n_standby=$(( n_standby + 1 ))
      continue
    fi
    if (( rc != 0 )); then
      continue
    fi
    if (( t < 10 || t > 90 )); then
      continue
    fi
    if (( t > max )); then
      max=$t
      hottest="$disk"
    fi
  done
  if (( max >= 0 )); then
    HDD_POLL_STATUS="ok"
    printf '%s %d\n' "$hottest" "$max"
  elif (( n_standby > 0 )); then
    HDD_POLL_STATUS="standby"
  fi
}

########################################
#            CONTROL HELPERS            #
########################################

ema_step() {
  local last="$1" raw="$2" rise="$3" fall="$4" pct delta step
  if (( raw > last )); then
    pct="$rise"
  else
    pct="$fall"
  fi
  delta=$(( raw - last ))
  step=$(( delta * pct / 100 ))
  # Integer division truncates toward zero: without this guard any
  # persistent delta smaller than 100/pct degrees produces a step of
  # zero and the EMA (and with it the fan speed) would freeze.
  if (( step == 0 && delta != 0 )); then
    if (( delta > 0 )); then
      step=1
    else
      step=-1
    fi
  fi
  printf '%d\n' $(( last + step ))
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

# NOTE: always write the PWM value, even when unchanged. The write
# doubles as the heartbeat for the zettlab_d8_fans driver watchdog:
# if these writes stop, the driver forces a safe (maximum) PWM after
# its watchdog timeout. The cost is one cheap sysfs write per cycle.
write_pwm() {
  printf '%d\n' "$2" >"$ZETTLAB_HWMON/$1"
}

# Damped/limited next PWM value (anti-hunting output shaping).
slew_target() {
  # slew_target <current_applied> <controller_target>
  local cur="$1" tgt="$2" step
  if (( tgt == cur )); then
    printf '%d\n' "$cur"
    return 0
  fi
  if (( tgt > cur )); then
    if (( tgt - cur <= PWM_DEADBAND )); then
      printf '%d\n' "$cur"
      return 0
    fi
    step=$(( tgt - cur ))
    if (( step > PWM_RISE_STEP )); then
      step=$PWM_RISE_STEP
    fi
  else
    if (( cur - tgt <= PWM_DEADBAND )); then
      printf '%d\n' "$cur"
      return 0
    fi
    step=$(( cur - tgt ))
    if (( step > PWM_FALL_STEP )); then
      step=$PWM_FALL_STEP
    fi
    step=$(( -step ))
  fi
  printf '%d\n' $(( cur + step ))
}

# Applied (slew-limited) PWM per output channel.
declare -A PWM_APPLIED

slew_write() {
  # slew_write <pwm_out> <target> <normal|force>
  # "force" bypasses shaping (safety paths, first write after start).
  local out="$1" tgt="$2" mode="$3" new
  if [[ "$mode" == "force" || -z "${PWM_APPLIED[$out]:-}" ]]; then
    new="$tgt"
  else
    new=$(slew_target "${PWM_APPLIED[$out]}" "$tgt")
  fi
  write_pwm "$out" "$new"
  PWM_APPLIED[$out]="$new"
}

log_temp_spike() {
  # log_temp_spike <previous_raw> <current_raw> <threshold_C> <label>
  local prev="$1" cur="$2" thr="$3" label="$4" delta
  if (( prev < 0 )); then
    return 0
  fi
  delta=$(( cur - prev ))
  if (( delta < 0 )); then
    delta=$(( -delta ))
  fi
  if (( delta >= thr )); then
    warn "Temperature spike ${label}: ${prev}C -> ${cur}C (delta ${delta}C)"
  fi
  return 0
}

########################################
#              SELF-TEST               #
########################################

if $RUN_TESTS; then
  pass=0
  fail=0
  check() {
    if [[ "$2" == "$3" ]]; then
      echo "ok   $1"
      pass=$(( pass + 1 ))
    else
      echo "FAIL $1 (got '$2', want '$3')" >&2
      fail=$(( fail + 1 ))
    fi
  }
  check "ema rise small step"  "$(ema_step 40 45 25 8)" "41"
  check "ema rise large step"  "$(ema_step 40 60 25 8)" "45"
  check "ema fall small step"  "$(ema_step 40 38 25 8)" "39"
  check "ema fall large step"  "$(ema_step 40 30 25 8)" "39"
  check "ema no change"        "$(ema_step 40 40 25 8)" "40"
  check "pwm clamps to min"    "$(calc_pwm 30 48 32 65 183)" "65"
  check "pwm clamps to max"    "$(calc_pwm 90 48 32 65 183)" "183"
  check "pwm linear"           "$(calc_pwm 60 48 32 65 183)" "103"
  check "slew rise limited"    "$(slew_target 100 110)" "106"
  check "slew fall limited"    "$(slew_target 100 95)"  "98"
  check "slew fall big gap"    "$(slew_target 100 60)"  "98"
  check "slew deadband rise"   "$(slew_target 100 103)" "100"
  check "slew deadband fall"   "$(slew_target 100 97)"  "100"
  check "slew no change"       "$(slew_target 100 100)" "100"
  echo "Self-test: $pass passed, $fail failed"
  exit $(( fail > 0 ? 1 : 0 ))
fi

########################################
#            EXIT SAFETY               #
########################################

on_exit() {
  local rc=$?
  # If the daemon dies unexpectedly, drive all fans to safe levels so
  # the system is never left unsupervised with slow fans. The driver
  # watchdog will also force maximum PWM once our writes stop.
  if [[ -n "${ZETTLAB_HWMON:-}" ]] && ! $DRY_RUN && ! $RUN_ONCE; then
    printf '%d\n' "$CPU_MAX_PWM" >"$ZETTLAB_HWMON/$CPU_PWM_OUT" 2>/dev/null || true
    for o in "${HDD_PWM_OUTS[@]}"; do
      printf '%d\n' "$HDD_FALLBACK_PWM" >"$ZETTLAB_HWMON/$o" 2>/dev/null || true
    done
    log "Daemon exiting; fans set to safe PWM (CPU=$CPU_MAX_PWM HDD=$HDD_FALLBACK_PWM)"
  fi
  exit "$rc"
}

trap on_exit EXIT

########################################
#              MAIN LOOP                #
########################################

cpu_ema=0
hdd_ema=0
prev_raw_cpu=-1
prev_raw_hdd=-1
cycle=0
cpu_fail_count=0
hdd_miss_count=0
cpu_forced=false
hdd_forced=false
HDD_POLL_STATUS="error"

while true; do

  # Apply reload safely in-loop
  if $RELOAD_CONFIG; then
    load_config
    RELOAD_CONFIG=false
  fi

  ##### CPU #####
  if read -r raw_cpu cpu_label < <(read_cpu_temp); then
    cpu_fail_count=0
    if $cpu_forced; then
      log "CPU temperature readable again; resuming normal control"
      cpu_forced=false
    fi

    log_temp_spike "$prev_raw_cpu" "$raw_cpu" "$CPU_TEMP_SPIKE_LOG" "CPU (${cpu_label:-unknown})"
    prev_raw_cpu="$raw_cpu"

    eff_cpu=$(( raw_cpu + CPU_TEMP_BIAS_C ))

    if (( cpu_ema == 0 )); then
      cpu_ema="$eff_cpu"
    else
      cpu_ema=$(ema_step "$cpu_ema" "$eff_cpu" "$CPU_RISE_EMA" "$CPU_FALL_EMA")
    fi

    if (( eff_cpu >= CPU_MAX_SAFE_TEMP_C )); then
      cpu_pwm="$CPU_MAX_PWM"
      cpu_write_mode="force"
    else
      cpu_pwm=$(calc_pwm "$cpu_ema" "$TARGET_CPU_C" "$CPU_GAIN_TENTHS" "$CPU_MIN_PWM" "$CPU_MAX_PWM")
      cpu_write_mode="normal"
    fi

    dry_log "CPU raw=${raw_cpu}C eff=${eff_cpu}C ema=${cpu_ema} pwm=${cpu_pwm} hottest=${cpu_label:-unknown}"
    if ! $DRY_RUN; then
      slew_write "$CPU_PWM_OUT" "$cpu_pwm" "$cpu_write_mode"
    fi
  else
    cpu_fail_count=$(( cpu_fail_count + 1 ))
    if (( cpu_fail_count >= CPU_READ_FAIL_LIMIT )); then
      if ! $cpu_forced; then
        warn "CPU temperature unreadable for ${cpu_fail_count} polls; forcing CPU_MAX_PWM=${CPU_MAX_PWM}"
        cpu_forced=true
      fi
      if ! $DRY_RUN; then
        slew_write "$CPU_PWM_OUT" "$CPU_MAX_PWM" "force"
      fi
    else
      dry_log "CPU read failed (${cpu_fail_count}/${CPU_READ_FAIL_LIMIT}); holding last PWM"
    fi
  fi

  ##### HDD #####
  if (( cycle % HDD_POLL_EVERY == 0 )); then
    if read -r disk raw_hdd < <(read_max_hdd_temp); then
      hdd_miss_count=0
      if $hdd_forced; then
        log "HDD temperatures readable again; resuming normal control"
        hdd_forced=false
      fi

      log_temp_spike "$prev_raw_hdd" "$raw_hdd" "$HDD_TEMP_SPIKE_LOG" "HDD ${disk##*/}"
      prev_raw_hdd="$raw_hdd"

      eff_hdd=$(( raw_hdd + HDD_TEMP_BIAS_C ))

      if (( hdd_ema == 0 )); then
        hdd_ema="$eff_hdd"
      else
        hdd_ema=$(ema_step "$hdd_ema" "$eff_hdd" "$HDD_RISE_EMA" "$HDD_FALL_EMA")
      fi

      hdd_pwm=$(calc_pwm "$hdd_ema" "$TARGET_HDD_C" "$HDD_GAIN_TENTHS" "$HDD_MIN_PWM" "$HDD_MAX_PWM")
      dry_log "HDD raw=${raw_hdd}C eff=${eff_hdd}C ema=${hdd_ema} pwm=${hdd_pwm} hottest=${disk##*/}"

      if ! $DRY_RUN; then
        for o in "${HDD_PWM_OUTS[@]}"; do
          slew_write "$o" "$hdd_pwm" "normal"
        done
      fi
    elif [[ "$HDD_POLL_STATUS" == "standby" ]]; then
      # All drives are spun down: no new heat is generated, so hold
      # the current PWM instead of forcing the (louder) fallback.
      hdd_miss_count=0
      dry_log "All drives in standby; holding HDD PWM"
    else
      hdd_miss_count=$(( hdd_miss_count + 1 ))
      # Re-enumerate so hot-added or removed drives are picked up.
      enumerate_drives
      if (( hdd_miss_count >= HDD_MISS_TOLERANCE )); then
        if ! $hdd_forced; then
          warn "HDD temps unavailable for ${hdd_miss_count} polls; forcing fallback PWM $HDD_FALLBACK_PWM"
          hdd_forced=true
        fi
        if ! $DRY_RUN; then
          for o in "${HDD_PWM_OUTS[@]}"; do
            slew_write "$o" "$HDD_FALLBACK_PWM" "force"
          done
        fi
      else
        dry_log "HDD SMART poll failed (${hdd_miss_count}/${HDD_MISS_TOLERANCE}); holding last PWM"
      fi
    fi
  fi

  cycle=$(( cycle + 1 ))

  sleep "$SLEEP_SECS"
  $RUN_ONCE && break
done
