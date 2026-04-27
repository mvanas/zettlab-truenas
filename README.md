# Zettlab D6/D8 Ultra – TrueNAS SCALE

Fan control for Zettlab D6U / D8U Ultra systems using TrueNAS SCALE.
TrueNAS 26 Beta is required and include the 10GB Realtek network drivers.

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

### 1. Make the Root Filesystem Writable
To completely disable rootfs protection run the following command
```
sudo /usr/local/libexec/disable-rootfs-protection
```

**Alternative method (not tried)**

Temporary disable write protection via:
```
sudo systemd-sysext unmerge
```

To restore the default immutable environment:
```
sudo systemd-sysext merge
```


---


### 2. Enable Developer Mode
```
sudo install-dev-tools
sudo apt update
```
---

### 3. Install DKMS and Build Dependencies
```
sudo apt install dkms devscripts debhelper dh-dkms -y
sudo apt install linux-headers-$(uname -r) -y
```
These packages are required **only** for building the driver.

---

## Installing the Zettlab Fan Driver

### 1. Prepare the DKMS source directory

```
sudo mkdir -p /usr/src/zettlab-d8-fans-0.0.1
```
Copy the following files into this directory:

- `Makefile`
- `dkms.conf`
- `zettlab_d8_fans.c`

---

### 2. Register, build, and install the module

```
sudo dkms add -m zettlab-d8-fans -v 0.0.1
sudo dkms build -m zettlab-d8-fans -v 0.0.1
sudo dkms install -m zettlab-d8-fans -v 0.0.1
```
---

### 3. Load the module
```
sudo modprobe zettlab_d8_fans
```
---

### 4. Verify hwmon Detection

```
sudo cat /sys/class/hwmon/hwmon*/name
```
Expected output includes:

zettlab_d8_fans

> Note: The `hwmonX` number varies per system and boot.  
> The fan control service automatically detects the correct node.

---

## Enable Driver Auto‑Loading at Boot
```
sudo echo zettlab_d8_fans | sudo tee /etc/modules-load.d/zettlab_d8_fans.conf
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
To verify the service is ruinning use:
```
sudo systemctl status fan-control.service
sudo journalctl -u fan-control.service -f
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
sudo systemctl reload fan-control.service
sudo journalctl -u fan-control.service -f
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
## Related Sources

zettlab-d8-fans driver (Haveacry / Dean Holland)
DKMS‑compatible kernel driver exposing the Zettlab D6U/D8U fan controller via hwmon.
https://github.com/Haveacry/zettlab-d8-fans


Zettlab Ubuntu installation guide (Henry Wong)
Detailed documentation and tooling for installing and running Ubuntu on Zettlab D6U/D8U systems.
https://github.com/henryxwong/zettlab-ubuntu


Alternative TrueNAS fan control approach (Ceveos)
Early community contribution demonstrating fan control and TrueNAS operation on Zettlab D6U/D8U hardware.
https://github.com/Ceveos/zettlab-d8-fans-truenas

### Acknowledgements
Thanks to everyone who shared findings, test results, and hardware details that helped make reliable fan control on Zettlab systems possible.
In particular:

Dean Holland (Haveacry / Speedster)
For developing and publishing the zettlab_d8_fans DKMS driver and documenting the fan controller behavior.

Henry Wong
For extensive work documenting Ubuntu installation and hardware enablement on Zettlab D6U/D8U platforms.

Ceveos
For early exploration and alternative approaches to running TrueNAS on Zettlab hardware, helping validate feasibility and direction.
