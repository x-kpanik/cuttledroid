#!/bin/bash
# Install APK and launch on all running Cuttlefish emulators
#
# Usage:
#   ./install-and-launch.sh /path/to/app.apk [package] [activity]
#
# Examples:
#   ./install-and-launch.sh ~/app.apk
#   ./install-and-launch.sh ~/app.apk com.example.app com.example.app.MainActivity

set -e

APK_PATH=${1:-~/app.apk}
PACKAGE=${2:-com.example.app}
ACTIVITY=${3:-com.example.app.MainActivity}
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-300}  # 5 minutes default

# Expand tilde
APK_PATH="${APK_PATH/#\~/$HOME}"

if [ ! -f "$APK_PATH" ]; then
  echo "ERROR: APK not found: $APK_PATH"
  exit 1
fi

echo "=== Install and Launch on All Emulators ==="
echo ""
echo "APK:            $APK_PATH"
echo "Package:        $PACKAGE"
echo "Activity:       $ACTIVITY"
echo "Install timeout: ${INSTALL_TIMEOUT}s"
echo ""

# Get list of connected devices (localhost, 127.0.0.1, or any IP:port with status "device")
# Filter only lines with status "device" (not offline, unauthorized, etc.)
DEVICES=$(adb devices | grep -E "^(localhost|127\.0\.0\.1|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+[[:space:]]+device$" | awk '{print $1}')

if [ -z "$DEVICES" ]; then
  echo "ERROR: No devices connected (status: device)"
  echo ""
  echo "Current adb devices output:"
  adb devices
  echo ""
  echo "Connect devices first:"
  echo "  adb connect localhost:6520"
  echo "  adb connect 127.0.0.1:6520"
  echo "  adb connect <ip>:6520"
  exit 1
fi

COUNT=$(echo "$DEVICES" | wc -l | tr -d ' ')
echo "Found $COUNT connected device(s) with status 'device'"
echo "Devices: $(echo $DEVICES | tr '\n' ' ')"
echo ""

# Step 1: Install APK in parallel with timeout
echo "=== Installing APK (parallel, timeout=${INSTALL_TIMEOUT}s) ==="
declare -A INSTALL_PIDS
declare -A INSTALL_RESULTS

for DEVICE in $DEVICES; do
  echo "Installing on $DEVICE..."
  (
    timeout $INSTALL_TIMEOUT adb -s $DEVICE install -r -g "$APK_PATH"
  ) &
  INSTALL_PIDS[$DEVICE]=$!
done

# Wait for all installs and collect results
INSTALL_FAILED=0
for DEVICE in $DEVICES; do
  PID=${INSTALL_PIDS[$DEVICE]}
  if wait $PID; then
    INSTALL_RESULTS[$DEVICE]="success"
    echo "  $DEVICE: installed"
  else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ]; then
      INSTALL_RESULTS[$DEVICE]="timeout"
      echo "  $DEVICE: TIMEOUT after ${INSTALL_TIMEOUT}s"
    else
      INSTALL_RESULTS[$DEVICE]="failed"
      echo "  $DEVICE: install failed (exit code: $EXIT_CODE)"
    fi
    INSTALL_FAILED=1
  fi
done
echo ""

# Step 2: Verify installation
echo "=== Verifying installation ==="
VERIFIED_DEVICES=""
for DEVICE in $DEVICES; do
  if [ "${INSTALL_RESULTS[$DEVICE]}" != "success" ]; then
    echo "  $DEVICE: skipped (install failed)"
    continue
  fi
  
  PM_PATH=$(adb -s $DEVICE shell pm path "$PACKAGE" 2>/dev/null || true)
  if [ -n "$PM_PATH" ]; then
    echo "  $DEVICE: $PM_PATH"
    VERIFIED_DEVICES="$VERIFIED_DEVICES $DEVICE"
  else
    echo "  $DEVICE: package not found after install"
  fi
done
VERIFIED_DEVICES=$(echo $VERIFIED_DEVICES | xargs)  # trim whitespace
echo ""

if [ -z "$VERIFIED_DEVICES" ]; then
  echo "ERROR: No devices with verified installation"
  exit 1
fi

# Step 3: Unlock screens
echo "=== Unlocking screens ==="
for DEVICE in $VERIFIED_DEVICES; do
  adb -s $DEVICE shell input keyevent 82 2>/dev/null || true
  adb -s $DEVICE shell input swipe 540 1800 540 800 2>/dev/null || true
done
echo "Screens unlocked"
echo ""

# Step 4: Disable immersive mode confirmations
echo "=== Disabling immersive mode ==="
for DEVICE in $VERIFIED_DEVICES; do
  adb -s $DEVICE shell settings put secure immersive_mode_confirmations confirmed 2>/dev/null || true
done
echo "Immersive mode confirmations disabled"
echo ""

# Step 5: Launch app with am start -W (waits for launch to complete)
echo "=== Launching app (am start -W) ==="
LAUNCH_FAILED=0
for DEVICE in $VERIFIED_DEVICES; do
  echo "Starting on $DEVICE..."
  START_OUTPUT=$(adb -s $DEVICE shell am start -W -n "$PACKAGE/$ACTIVITY" 2>&1)
  
  # Parse and display result
  STATUS=$(echo "$START_OUTPUT" | grep -E "^Status:" | awk '{print $2}')
  ACTIVITY_LINE=$(echo "$START_OUTPUT" | grep -E "^Activity:" | awk '{print $2}')
  THIS_TIME=$(echo "$START_OUTPUT" | grep -E "^ThisTime:" | awk '{print $2}')
  TOTAL_TIME=$(echo "$START_OUTPUT" | grep -E "^TotalTime:" | awk '{print $2}')
  
  if [ "$STATUS" = "ok" ]; then
    echo "  $DEVICE: Status=$STATUS, Activity=$ACTIVITY_LINE"
    echo "     ThisTime=${THIS_TIME}ms, TotalTime=${TOTAL_TIME}ms"
  else
    echo "  $DEVICE: Status=$STATUS"
    echo "     Output: $START_OUTPUT"
    LAUNCH_FAILED=1
  fi
  
  sleep 1
done
echo ""

if [ $INSTALL_FAILED -eq 0 ] && [ $LAUNCH_FAILED -eq 0 ]; then
  echo "=== All Done! ==="
else
  echo "=== Done with warnings ==="
fi
