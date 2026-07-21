#!/bin/bash
# =====================================================================
# FlatSat Mission Control - One-Click Launcher (macOS)
# Double-click this file in Finder to start everything.
# (First time: right-click > Open to bypass Gatekeeper, or run
#  `chmod +x run_mission_control.command` in Terminal once.)
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
  || $PY -m pip install --quiet --user -r "$DIR/PC_Bridge/requirements.txt" 2>/dev/null \
  || echo "      (Could not auto-install dependencies; continuing anyway.)"

# ---- 2. Bridge ----
echo "[2/3] Starting ground-station bridge..."
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
APP="build/macos/Build/Products/Release/flatsat_dashboard.app"
if [ -d "$APP" ]; then
  open -W "$APP"
elif command -v flutter >/dev/null 2>&1; then
  flutter run -d macos
else
  echo "ERROR: No built app found and Flutter is not installed."
  echo "Either install Flutter, or build the app once with: flutter build macos"
  read -r -p "Press Enter to close..."
  exit 1
fi
