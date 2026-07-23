#!/bin/bash
# =====================================================================
# FlatSat Mission Control - One-Click Launcher (Linux / Raspberry Pi)
# Double-click this file (or run ./run_mission_control.sh) to:
#   1. Install the Python dependencies (first run only)
#   2. Start the ground-station bridge
#   3. Open the dashboard
#   4. Clean up automatically when you close it
# =====================================================================

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$DIR"

echo "==========================================="
echo "   Starting FlatSat Mission Control..."
echo "==========================================="

# ---- Python check ----
PY=python3
if ! command -v $PY >/dev/null 2>&1; then
  echo "ERROR: Python 3 is required but was not found."
  echo "Install it from https://www.python.org/downloads/ and try again."
  read -r -p "Press Enter to close..."
  exit 1
fi

# ---- 1. Dependencies ----
echo "[1/3] Checking Python dependencies..."
$PY -m pip install --quiet --disable-pip-version-check -r "$DIR/PC_Bridge/requirements.txt" 2>/dev/null \
  || $PY -m pip install --quiet --user --break-system-packages -r "$DIR/PC_Bridge/requirements.txt" 2>/dev/null \
  || echo "      (Could not auto-install dependencies; continuing anyway.)"

# ---- 2. Bridge ----
echo "[2/3] Starting ground-station bridge..."
# Stop any leftover bridge so the new one can bind port 8080 AND re-open the
# serial port (a stale bridge holding 8080 makes the new one crash on bind,
# leaving the app talking to a bridge that has no serial data).
pkill -f "gs_bridge.py" 2>/dev/null && sleep 0.5
# Free port 8080 if something still holds it (fuser is the most portable tool).
fuser -k 8080/tcp 2>/dev/null && sleep 0.5
cd "$DIR/PC_Bridge"
$PY gs_bridge.py > bridge_log.txt 2>&1 &
BRIDGE_PID=$!
cleanup() {
  echo ""
  echo "Stopping bridge (PID $BRIDGE_PID)..."
  kill "$BRIDGE_PID" 2>/dev/null
  echo "Done. Goodbye!"
}
trap cleanup EXIT
sleep 1.5

# ---- 3. Dashboard ----
echo "[3/3] Launching dashboard..."
cd "$DIR/Dashboard"
BIN="build/linux/x64/release/bundle/flatsat_dashboard"
if [ -x "$BIN" ]; then
  "./$BIN"
elif command -v flutter >/dev/null 2>&1; then
  flutter run -d linux
else
  echo "ERROR: No built app found and Flutter is not installed."
  echo "Either install Flutter, or build the app once with: flutter build linux"
  read -r -p "Press Enter to close..."
  exit 1
fi
