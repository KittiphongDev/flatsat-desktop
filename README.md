# FlatSat Mission Control

Ground-station dashboard for the FlatSat satellite learning kit. It shows live
telemetry, sends commands, and manages images from the satellite over the
433 MHz radio link and a USB-connected ground station.

```
App (Flutter dashboard)  ⇄  Bridge (gs_bridge.py)  ⇄  USB  ⇄  Ground Station
                                                                   ⇅ 433 MHz radio
                                                          COMMS ⇄ OBC ⇄ EPS / GPS / Camera
```

---

## Quick start (one click)

Plug the **ground station** into the computer with a USB cable, then run the
launcher for your operating system:

| Operating system      | Double-click this file          |
|-----------------------|---------------------------------|
| Windows               | `run_mission_control.bat`       |
| macOS                 | `run_mission_control.command`   |
| Linux / Raspberry Pi  | `run_mission_control.sh`        |

The launcher automatically:

1. Installs the Python dependencies (first run only)
2. Starts the ground-station bridge
3. Opens the dashboard
4. Stops the bridge when you close the app

That's it — no ports or settings to configure by hand.

> **macOS first run:** right-click `run_mission_control.command` → **Open** once
> to get past Gatekeeper. After that a double-click works.

---

## Using the dashboard

A banner at the top of the app always tells you where the connection stands:

- **Starting ground station software…** – the bridge is still coming up.
- **No ground station detected on USB** – plug in the ground station, or use the
  **port dropdown** to pick it, then press **Reconnect**. Close the Arduino
  Serial Monitor if it's open (it locks the USB port).
- **Waiting for satellite…** – USB is fine; power on the OBC and COMMS boards and
  make sure the antennas are attached. Beacons arrive about every 10 seconds.
- **Live** – telemetry is flowing. 🎉

Use the sun/moon button (top-right) to switch between the light and dark themes.

---

## Requirements

- **Python 3** (with `pip`) – the launcher installs `pyserial` and `websockets`.
- **Flutter** – only needed if you run from source. See "Build once" below to
  avoid requiring Flutter on every computer.

---

## Build once (recommended for classrooms)

Building the app ahead of time means the launcher runs a ready-made app and the
students' computers **don't need Flutter installed** — only Python.

From the `Dashboard` folder:

```bash
flutter pub get
flutter build linux      # or:  flutter build windows   /   flutter build macos
```

The launcher automatically prefers the built app if it finds one, and falls back
to `flutter run` otherwise.

---

## Troubleshooting

**Link status stays red / "No ground station detected"**
- Close the **Arduino IDE Serial Monitor** — it holds the USB port open.
- Confirm the ground station is plugged in and powered.
- Open the port dropdown in the banner and pick the device manually
  (STM32 boards usually appear as `ttyACM0` on Linux, `usbmodem…` on macOS, or a
  `COM…` port on Windows).

**"Permission denied" on the serial port (Linux / Raspberry Pi)**
```bash
sudo usermod -a -G dialout $USER
```
Then log out and back in.

**Banner shows "Waiting for satellite…" and never goes Live**
- The USB side is fine; the radio side isn't. Power the **OBC** and **COMMS**
  boards and attach both antennas. The OBC beacons every ~10 s.

**Need to see detailed logs**
- The bridge writes everything to `PC_Bridge/bridge_log.txt`.

---

## Manual start (advanced)

If you'd rather run the pieces yourself:

```bash
# 1) Start the bridge (auto-detects the port; override if needed)
cd PC_Bridge
pip install -r requirements.txt
python3 gs_bridge.py                 # or: python3 gs_bridge.py /dev/ttyACM0
#   or:  FLATSAT_SERIAL_PORT=/dev/ttyACM0 python3 gs_bridge.py

# 2) Start the app
cd ../Dashboard
flutter run
```

---

## Project layout

```
FlatSat_New_Architecture/
├── run_mission_control.sh        # Linux / Raspberry Pi launcher
├── run_mission_control.command   # macOS launcher
├── run_mission_control.bat       # Windows launcher
├── Dashboard/                    # Flutter dashboard app
├── PC_Bridge/
│   ├── gs_bridge.py              # Serial (KISS) ⇄ WebSocket bridge
│   └── requirements.txt          # Python dependencies
├── OBC/    OBC.ino                # On-Board Computer firmware
├── COMMU/  COMMU.ino              # Communications firmware
└── GS/     GS.ino                # Ground Station firmware
```
