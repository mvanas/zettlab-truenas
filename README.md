# Zettlab D6/D8 Ultra – TrueNAS SCALE

Fan control for Zettlab D6U / D8U Ultra systems using TrueNAS SCALE.

---

## Overview

This repository provides a complete solution for **dynamic, temperature‑based fan control** on Zettlab D6U / D8U Ultra NAS devices.

The solution consists of two main components:

1. **`zettlab_d8_fans` DKMS kernel driver**  
   Exposes the Zettlab fan controller to Linux via `hwmon`

2. **`fan-control.sh` systemd service**  
   Continuously regulates fan speeds based on:
   - CPU temperature (package or hottest sensor)
   - Hottest detected HDD temperature via SMART

---

## Disclaimer

**⚠ WARNING:**  
This project directly controls hardware fan speeds. Improper configuration can lead to overheating or hardware damage.

- Always verify minimum safe fan speeds  
- Test changes using dry‑run modes  
- Monitor system temperatures after configuration changes  
- Use at your own risk  

---

## Kernel Driver Requirement – `zettlab_d8_fans`

Fan control requires a kernel driver to expose the Zettlab fan controller via **hwmon**.

### Driver Source

Upstream repository:

https://github.com/Haveacry/zettlab-d8-fans

For convenience, the following files are included in this repository:
- `Makefile`
- `dkms.conf`
- `zettlab_d8_fans.c`

---

## TrueNAS SCALE – System Preparation (Required)

TrueNAS SCALE is **immutable by default** and does **not** include DKMS or kernel development tools.

### 1. Temporarily Make the Root Filesystem Writable
```
systemd-sysext unmerge
```

### 2. Enable Developer Mode
```
install-dev-tools
apt update
```
---

### 3. Install DKMS and Build Dependencies
```
apt install dkms devscripts debhelper dh-dkms -y
apt install linux-headers-$(uname -r) -y
```
These packages are required **only** for building the driver.

---

## Installing the Zettlab Fan Driver

### 1. Prepare the DKMS source directory

```
mkdir -p /usr/src/zettlab-d8-fans-0.0.1
```
Copy the following files into this directory:

- `Makefile`
- `dkms.conf`
- `zettlab_d8_fans.c`

---

### 2. Register, build, and install the module

```
dkms add -m zettlab-d8-fans -v 0.0.1
dkms build -m zettlab-d8-fans -v 0.0.1
dkms install -m zettlab-d8-fans -v 0.0.1
```
---

### 3. Load the module
```
modprobe zettlab_d8_fans
```
---

### 4. Verify hwmon Detection

```
cat /sys/class/hwmon/hwmon*/name
```
Expected output includes:

zettlab_d8_fans

> Note: The `hwmonX` number varies per system and boot.  
> The fan control service automatically detects the correct node.

---

## Enable Driver Auto‑Loading at Boot
```
echo zettlab_d8_fans | sudo tee /etc/modules-load.d/zettlab_d8_fans.conf
```

---

## Fan Control Service

### Installation

```
sudo cp fan-control.sh /usr/local/sbin/
sudo chmod +x /usr/local/sbin/fan-control.sh
sudo cp fan-control.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now fan-control.service
```
---

## Configuration – `/etc/fan-control`

Fan control behavior is customized via:


/etc/fan-control

- Built‑in defaults ensure safe operation
- Only defined variables override defaults
- Includes extensive inline documentation


See fan-control.example in this repository.

---

## Live Reload

After editing `/etc/fan-control`:
```
systemctl reload fan-control.service
```
- No restart
- No fan interruption
- Configuration applied on next control loop

---

## lm‑sensors Integration (Optional)

To display correct PWM percentages in `lm-sensors`, add to `/etc/sensors3.conf`:

```
chip "zettlab_d8_fans-*"
   compute pwm1 (@ * 200 / 183), (@ * 183 / 200)
   compute pwm2 (@ * 200 / 183), (@ * 183 / 200)
   compute pwm3 (@ * 200 / 183), (@ * 183 / 200)
```
---

## Restore Read‑Only System State (Required)

After installing drivers and configuring services:
```
systemd-sysext merge
```
This restores the default immutable TrueNAS SCALE environment.

---

