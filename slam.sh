#!/bin/bash
# SLAM launch wrapper: auto-save grid map + 3D PCD + (optional) rosbag on exit
# Usage:
#   ./slam.sh [--no-bag] [extra launch args...]
# Examples:
#   ./slam.sh world:=rmuc_2025                         # real-world: record rosbag
#   ./slam.sh --no-bag world:=rmuc_2026 \              # simulation: skip rosbag
#       auto_save_map:=True auto_save_map_interval:=20.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source install/setup.bash

# --- parse --no-bag and strip it from "$@" ---
NO_BAG=0
LAUNCH_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-bag) NO_BAG=1 ;;
        *) LAUNCH_ARGS+=("$arg") ;;
    esac
done
set -- "${LAUNCH_ARGS[@]}"

NAMESPACE="red_standard_robot1"
MAP_SAVE_DIR="src/pb2025_sentry_nav/point_lio/PCD"
MAP_NAME="scans"
PCD_FILE="${MAP_SAVE_DIR}/${MAP_NAME}.pcd"
BAG_NAME="slam_bag_$(date +%Y%m%d_%H%M%S)"
BAG_PATH="${MAP_SAVE_DIR}/${BAG_NAME}"

BAG_PID=""
if [ "$NO_BAG" -eq 0 ]; then
    echo "[slam.sh] Starting rosbag recording to ${BAG_PATH} ..."
    setsid ros2 bag record -a -o "${BAG_PATH}" &
    BAG_PID=$!
    echo "[slam.sh] Rosbag PID: ${BAG_PID}"
    sleep 2
else
    echo "[slam.sh] --no-bag: skipping rosbag recording"
fi

# sigterm_timeout / sigkill_timeout: passed as launch arguments (LaunchConfiguration),
# so all ExecuteProcess actions wait long enough for point_lio to flush PCD.
# Using launch args instead of CLI flags for compatibility with older ros2 launch.
setsid ros2 launch \
    pb2025_nav_bringup rm_navigation_simulation_launch.py \
    slam:=True sigterm_timeout:=30 sigkill_timeout:=60 "$@" &
LAUNCH_PID=$!

cleanup() {
    trap '' SIGINT SIGTERM
    local cleanup_start=$(date +%s)
    echo ""
    echo "[slam.sh] Cleanup start at $(date)"

    # 1) Save 2D grid map FIRST — while map_saver lifecycle node is still active.
    #    Must happen BEFORE the launch SIGINT, otherwise map_saver enters
    #    deactivating state and the service call times out.
    echo "[slam.sh] Saving final grid map (before launch shutdown)..."
    timeout 15 ros2 service call /"${NAMESPACE}"/map_saver/save_map \
        nav2_msgs/srv/SaveMap \
        "{map_topic: '/${NAMESPACE}/map', map_url: '${MAP_SAVE_DIR}/${MAP_NAME}', image_format: 'pgm', map_mode: 'trinary', free_thresh: 0.25, occupied_thresh: 0.65}" \
        || echo "[slam.sh] map_saver call failed/timed out — continuing shutdown"

    # 2) SIGINT to launch — point_lio gets max time to reach writeBinary at end of main
    echo "[slam.sh] Shutting down launch (point_lio will flush PCD)..."
    kill -INT -$LAUNCH_PID 2>/dev/null

    # 3) Stop rosbag in parallel (only if it was started)
    BAG_CLEANUP_PID=""
    if [ -n "$BAG_PID" ]; then
        (
            kill -INT -$BAG_PID 2>/dev/null
            sleep 5
            kill -0 $BAG_PID 2>/dev/null && kill -TERM -$BAG_PID 2>/dev/null
            wait $BAG_PID 2>/dev/null
            echo "[slam.sh] Rosbag saved to ${BAG_PATH}/"
        ) &
        BAG_CLEANUP_PID=$!
    fi

    # 4) Wait for launch and rosbag cleanup
    wait $LAUNCH_PID 2>/dev/null
    [ -n "$BAG_CLEANUP_PID" ] && wait $BAG_CLEANUP_PID 2>/dev/null

    # 5) Verify PCD mtime updated since cleanup_start (up to 60s)
    for i in $(seq 1 60); do
        if [ -f "$PCD_FILE" ] && \
           [ "$(stat -c %Y "$PCD_FILE" 2>/dev/null || echo 0)" -ge "$cleanup_start" ]; then
            BACKUP="${PCD_FILE%.pcd}_$(date +%Y%m%d_%H%M%S).pcd"
            cp "$PCD_FILE" "$BACKUP"
            echo "[slam.sh] PCD updated: $PCD_FILE ($(du -h "$PCD_FILE" | cut -f1))"
            echo "[slam.sh] Backup:      $BACKUP"
            exit 0
        fi
        sleep 1
    done
    echo "[slam.sh] WARNING: PCD mtime did not update — point_lio may have been killed before flush."
    echo "          Try increasing sigterm_timeout / sigkill_timeout in the launch command."
    exit 1
}

trap cleanup SIGINT

while kill -0 $LAUNCH_PID 2>/dev/null; do
    wait $LAUNCH_PID 2>/dev/null
done
