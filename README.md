# CODESYS Installation Scripts

Automated installation of **CODESYS License Server SL** and **CODESYS Virtual Control SL** on a Linux target.

---

## Required files

Place all of the following in the same folder before running:

```
install_codesys.sh
uninstall_codesys.sh
CODESYS LicenseServer for Linux SL 4.19.0.0.package
CODESYS Virtual Control for Linux SL 4.19.0.0.package
codemeter-lite_<version>_<arch>.deb
```

> `.package` files are standard ZIP archives provided by CODESYS or on the WAGO Download Center.  
> `codemeter-lite` can be found in CODESYS installation C:\Program Files\CODESYS 3.5.X.X\CODESYS\CODESYS CodeMeter for Linux SL\Delivery

---

## Installation

```bash
sudo ./install_codesys.sh
```

The script requires `python3`, `docker`, and `dpkg` to be installed.

### What it does

**Module 1 — License Server**

1. Detects the `.package` file containing "license" in its name and extracts it.
2. Installs **CodeMeter Lite** (`dpkg -i codemeter-lite_*.deb`) as a prerequisite — the CodeMeter service starts automatically.
3. Installs the three License Server Debian packages in order: `licenseserver` → `wbmbase` → `wbmlicensing`.
4. Verifies that the `codesyslicenseserver` systemd service is active.

**Module 2 — Virtual Control**

1. Detects the `.package` file containing "virtual" in its name, detects the CPU architecture (`x86_64` → `virtuallinux`, `aarch64` → `virtuallinuxarm64`, `armv7l` → `virtuallinuxarm`), and extracts the matching Delivery folder.
2. Loads the Docker image (`Docker_*.tar.gz`) into the local Docker daemon.
3. Deploys `VirtualControlAPI.py` to `/root/`.
4. Creates a Virtual Control instance named `vcontrol` via `VirtualControlAPI.py`, configures the Docker image, and enables autostart (registers `VirtualControlAPI.service` in systemd).
5. Starts the instance.

---

## Post-installation

| Component | Command |
|---|---|
| License Server status | `systemctl status codesyslicenseserver` |
| License Server web UI | `http://<device-ip>:8080` |
| Virtual Control status | `python3 /root/VirtualControlAPI.py --list` |
| Stop instance | `python3 /root/VirtualControlAPI.py --stop vcontrol` |
| Start instance | `python3 /root/VirtualControlAPI.py --run vcontrol` |
| View logs | `docker logs -f vcontrol` |

---

## Uninstall

```bash
sudo ./uninstall_codesys.sh              # remove everything
sudo ./uninstall_codesys.sh --vcontrol   # Virtual Control only
sudo ./uninstall_codesys.sh --licenseserver
sudo ./uninstall_codesys.sh --codemeter
```

The uninstall script stops and removes the Docker container and images, purges the License Server and CodeMeter Lite packages, removes all residual files, and cleans up the dpkg state.
