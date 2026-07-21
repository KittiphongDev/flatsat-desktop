#!/bin/bash
# FlatSat Mission Control - Auto-Launcher
# This script starts the Python Bridge in the background and then launches the Flutter Dashboard.
# When you close the dashboard, it automatically cleans up the Python background process.

# Get the directory where this script is located
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

echo "==========================================="
echo "🚀 Starting FlatSat Mission Control..."
echo "==========================================="

# 1. Start the Python Bridge in the background
echo "[1/2] Starting Python Bridge (gs_bridge.py)..."
cd "$DIR/PC_Bridge"
# Run python bridge and redirect output to a log file instead of cluttering the screen
python3 gs_bridge.py > bridge_log.txt 2>&1 &
BRIDGE_PID=$!
echo "      Bridge running in background (PID: $BRIDGE_PID)"

# Give the bridge a second to start up
sleep 1.5

# 2. Start the Flutter Dashboard
echo "[2/2] Launching Flutter Dashboard..."
cd "$DIR/Dashboard"
# You can change this to run the compiled release binary once you build it:
# ./build/linux/x64/release/bundle/flatsat_dashboard
flutter run -d linux

# 3. Cleanup after Dashboard is closed
echo "==========================================="
echo "🛑 Dashboard closed. Cleaning up..."
kill $BRIDGE_PID
echo "✅ Python bridge stopped. Goodbye!"
echo "==========================================="
