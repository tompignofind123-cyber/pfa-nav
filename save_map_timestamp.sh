#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source install/setup.bash

NAMESPACE="red_standard_robot1"
MAP_DIR="src/pb2025_sentry_nav/pb2025_nav_bringup/map/simulation"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
MAP_BASENAME="auto_map_${TIMESTAMP}"
MAP_URL="${MAP_DIR}/${MAP_BASENAME}"

mkdir -p "${MAP_DIR}"

echo "[save_map_timestamp] Saving map to: ${MAP_URL}.pgm/.yaml"
ros2 service call "/${NAMESPACE}/map_saver/save_map" nav2_msgs/srv/SaveMap \
  "{map_topic: '/${NAMESPACE}/map', map_url: '${MAP_URL}', image_format: 'pgm', map_mode: 'trinary', free_thresh: 0.25, occupied_thresh: 0.65}"

echo "[save_map_timestamp] Done:"
echo "  ${MAP_URL}.pgm"
echo "  ${MAP_URL}.yaml"
