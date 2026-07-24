#!/usr/bin/env bash
# =====================================================================
#  FlatSat - Install the Linux desktop icon + menu entry
#
#  Linux binaries don't embed an icon like a Windows .exe, and
#  flutter_launcher_icons doesn't support Linux. So the icon comes from:
#    1. the GTK window icon (handled in linux/runner/my_application.cc)
#    2. a .desktop entry, which this script installs
#
#  Usage:  bash install_linux_icon.sh
# =====================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_ID="flatsat-dashboard"
ICON_ROOT="$HOME/.local/share/icons/hicolor"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/$APP_ID.desktop"

echo "==========================================="
echo "   Installing FlatSat desktop icon..."
echo "==========================================="
echo

# ---- Work out which layout we're running from ----
# This script has to work in two very different places:
#   A. the source repo      -> icon under Dashboard/assets, launch via the .sh
#   B. a distributed build  -> icon under data/flutter_assets, launch the binary
# Case B is what end users get when they download a built bundle, so the
# script must not assume the repo layout.
if [ -f "$HERE/Dashboard/assets/icons/app_icon.png" ]; then
  LAYOUT="source repo"
  SRC_ICON="$HERE/Dashboard/assets/icons/app_icon.png"
  EXEC_CMD="$HERE/run_mission_control.sh"
  WORKDIR="$HERE"
elif [ -f "$HERE/data/flutter_assets/assets/icons/app_icon.png" ]; then
  LAYOUT="built bundle"
  SRC_ICON="$HERE/data/flutter_assets/assets/icons/app_icon.png"
  EXEC_CMD="$HERE/flatsat_dashboard"
  WORKDIR="$HERE"
elif [ -f "$HERE/bundle/data/flutter_assets/assets/icons/app_icon.png" ]; then
  LAYOUT="built bundle (parent folder)"
  SRC_ICON="$HERE/bundle/data/flutter_assets/assets/icons/app_icon.png"
  EXEC_CMD="$HERE/bundle/flatsat_dashboard"
  WORKDIR="$HERE/bundle"
else
  echo "ERROR: could not find app_icon.png."
  echo "Run this script from either:"
  echo "  - the FlatSat_New_Architecture folder (source), or"
  echo "  - the folder containing the built Linux bundle."
  exit 1
fi

echo "Detected layout: $LAYOUT"
echo "  icon: $SRC_ICON"
echo "  exec: $EXEC_CMD"
echo

if [ ! -e "$EXEC_CMD" ]; then
  echo "ERROR: launch target not found:"
  echo "  $EXEC_CMD"
  exit 1
fi

chmod +x "$EXEC_CMD" || true

# ---- 1. Install the icon into the hicolor theme ----
# If ImageMagick is available, generate proper sizes so the icon stays crisp
# in the menu, the dock and the window switcher. Otherwise install the
# original at 512x512, which every desktop environment will scale.
if command -v convert >/dev/null 2>&1; then
  echo "[1/3] Installing icon at multiple sizes (ImageMagick found)..."
  for SIZE in 16 24 32 48 64 128 256 512; do
    DEST_DIR="$ICON_ROOT/${SIZE}x${SIZE}/apps"
    mkdir -p "$DEST_DIR"
    convert "$SRC_ICON" -resize "${SIZE}x${SIZE}" "$DEST_DIR/$APP_ID.png"
  done
else
  echo "[1/3] Installing icon at 512x512 (install ImageMagick for more sizes)..."
  DEST_DIR="$ICON_ROOT/512x512/apps"
  mkdir -p "$DEST_DIR"
  cp -f "$SRC_ICON" "$DEST_DIR/$APP_ID.png"
fi

# ---- 2. Write the .desktop entry ----
echo "[2/3] Writing menu entry..."
mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=FlatSat Mission Control
GenericName=Ground Station Dashboard
Comment=Live telemetry, commanding and imaging for the FlatSat kit
Exec=$EXEC_CMD
Path=$WORKDIR
Icon=$APP_ID
Terminal=false
Categories=Education;Science;Utility;
Keywords=satellite;telemetry;ground station;flatsat;
StartupNotify=true
StartupWMClass=flatsat_dashboard
EOF
chmod +x "$DESKTOP_FILE"

# ---- 3. Refresh the desktop caches ----
echo "[3/3] Refreshing desktop caches..."
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$ICON_ROOT" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

echo
echo "==========================================="
echo " Done."
echo "   Menu entry: $DESKTOP_FILE"
echo "   Icon:       $ICON_ROOT/<size>/apps/$APP_ID.png"
echo
echo " 'FlatSat Mission Control' should now appear in your"
echo " applications menu. If it doesn't show right away, log"
echo " out and back in to refresh the desktop database."
echo "==========================================="
