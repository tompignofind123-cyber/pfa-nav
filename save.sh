#!/bin/bash
# Save current 2D grid map as game.pgm/yaml into reality/ + simulation/ dirs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { echo "Failed to cd to $SCRIPT_DIR"; exit 1; }

source /opt/ros/humble/setup.bash
source install/setup.bash

MAP_DIR="src/pb2025_sentry_nav/pb2025_nav_bringup/map/reality"
BACKUP_MAP_DIR="src/pb2025_sentry_nav/pb2025_nav_bringup/map/simulation"
mkdir -p "$MAP_DIR" "$BACKUP_MAP_DIR"

ros2 run nav2_map_server map_saver_cli -f game

cp game.yaml "$BACKUP_MAP_DIR/"
cp game.pgm  "$BACKUP_MAP_DIR/"
mv game.yaml "$MAP_DIR/"
mv game.pgm  "$MAP_DIR/"

echo "Map saved to $MAP_DIR and $BACKUP_MAP_DIR"
