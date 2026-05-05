#!/bin/bash
# Navigation/localization launch wrapper.
# Usage: ./nav.sh [extra launch args...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source /opt/ros/humble/setup.bash
source install/setup.bash

NAMESPACE="red_standard_robot1"
MAP_SAVE_DIR="src/pb2025_sentry_nav/point_lio/PCD"
PCD_FILE="${MAP_SAVE_DIR}/scans.pcd"
GAME_PCD_DIR="src/pb2025_sentry_nav/pb2025_nav_bringup/pcd/reality"

# Stage prior map: copy last scans.pcd as game.pcd
if [ -f "$PCD_FILE" ]; then
    mkdir -p "$GAME_PCD_DIR"
    cp "$PCD_FILE" "$GAME_PCD_DIR/game.pcd"
    echo "[nav.sh] Copied scans.pcd -> $GAME_PCD_DIR/game.pcd"
else
    echo "[nav.sh] WARNING: $PCD_FILE not found; nav will start without prior map."
fi

echo "[nav.sh] Environment loaded."

setsid ros2 launch \
    pb2025_nav_bringup rm_navigation_reality_launch.py \
    world:=game slam:=False use_robot_state_pub:=True \
    sigterm_timeout:=30 sigkill_timeout:=60 "$@" &
LAUNCH_PID=$!

cleanup() {
    trap '' SIGINT SIGTERM
    local cleanup_start=$(date +%s)
    echo ""
    echo "[nav.sh] Shutting down launch (point_lio will flush PCD if pcd_save_en is set)..."
    kill -INT -$LAUNCH_PID 2>/dev/null
    wait $LAUNCH_PID 2>/dev/null

    for i in $(seq 1 60); do
        if [ -f "$PCD_FILE" ] && \
           [ "$(stat -c %Y "$PCD_FILE" 2>/dev/null || echo 0)" -ge "$cleanup_start" ]; then
            BACKUP="${PCD_FILE%.pcd}_$(date +%Y%m%d_%H%M%S).pcd"
            cp "$PCD_FILE" "$BACKUP"
            echo "[nav.sh] PCD updated: $PCD_FILE"
            echo "[nav.sh] Backup:      $BACKUP"
            exit 0
        fi
        sleep 1
    done
    echo "[nav.sh] PCD not updated (expected if running pure localization without pcd_save_en)."
    exit 0
}
trap cleanup SIGINT

while kill -0 $LAUNCH_PID 2>/dev/null; do
    wait $LAUNCH_PID 2>/dev/null
done
