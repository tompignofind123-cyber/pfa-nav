#!/bin/bash
# kill_ros.sh — One-shot cleanup for ROS 2 / Gazebo / Gz Sim leftovers.
#
# Usage:
#   ./kill_ros.sh            # list, ask y/n, then kill (INT -> TERM -> KILL)
#   ./kill_ros.sh -y         # skip confirmation
#   ./kill_ros.sh -n         # dry-run: list only, kill nothing
#   ./kill_ros.sh --keep-shm # do NOT clean /dev/shm/* (DDS shared memory)
#   ./kill_ros.sh -v         # verbose: print every match decision
#
# Safe by design:
#   - never kills self / parent shell / login shell
#   - skips editors / IDEs / colcon / rosdep even if cmdline mentions ros
#   - SIGINT first (5s grace -> trap can write PCD), then SIGTERM (3s), then SIGKILL

set -u

# ---- colors ----
if [ -t 1 ]; then
    C_RED=$'\e[31m'; C_YELLOW=$'\e[33m'; C_GREEN=$'\e[32m'
    C_CYAN=$'\e[36m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_RED=""; C_YELLOW=""; C_GREEN=""; C_CYAN=""; C_DIM=""; C_RST=""
fi

# ---- args ----
DRY_RUN=0
ASSUME_YES=0
KEEP_SHM=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run)  DRY_RUN=1 ;;
        -y|--yes)      ASSUME_YES=1 ;;
        --keep-shm)    KEEP_SHM=1 ;;
        -v|--verbose)  VERBOSE=1 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "${C_RED}Unknown arg: $arg${C_RST}" >&2
            exit 2
            ;;
    esac
done

# ---- protected PIDs (self + parent shell chain) ----
SELF_PID=$$
PARENT_PID=$PPID
# Whole ancestor chain — never touch any of them
ANCESTORS=()
pid=$PARENT_PID
while [ "$pid" -gt 1 ] 2>/dev/null; do
    ANCESTORS+=("$pid")
    next=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$next" ] || [ "$next" = "$pid" ] && break
    pid=$next
done

is_protected() {
    local target=$1
    [ "$target" = "$SELF_PID" ] && return 0
    for a in "${ANCESTORS[@]}"; do
        [ "$a" = "$target" ] && return 0
    done
    return 1
}

# ---- match patterns ----
# Each pattern is matched against full cmdline (pgrep -f). Order doesn't matter.
ROS_PATTERNS=(
    # Core ROS 2
    '_ros2_daemon'
    'ros2 launch'
    'ros2 run'
    'ros2 bag record'
    'ros2 bag play'
    'ros2 topic'
    'ros2 service'
    'ros2 param'
    'component_container'
    'component_container_mt'
    'component_container_isolated'
    'rviz2'
    'rqt_'
    # Common ROS 2 nodes (use path-prefixes when generic names risk false positives)
    'robot_state_publisher'
    'joint_state_publisher'
    'controller_manager'
    'ros2_control_node'
    'controller_manager/spawner'
    # Nav2
    'nav2_amcl'
    'nav2_planner'
    'nav2_controller'
    'nav2_bt_navigator'
    'nav2_lifecycle_manager'
    'nav2_map_server'
    'nav2_behavior'
    'nav2_smoother'
    'nav2_velocity_smoother'
    'nav2_collision_monitor'
    'nav2_waypoint_follower'
    'slam_toolbox'
    'pointcloud_to_laserscan'
    # Bridges
    'parameter_bridge'
    'ros_gz_bridge'
    'ros_gz_image'
    # This project
    'point_lio'
    'pb2025_'
    'rm_navigation'
    'rmu_gazebo'
)

GAZEBO_PATTERNS=(
    # Classic Gazebo
    'gzserver'
    'gzclient'
    # Modern Gz Sim (binary `gz sim` or via ruby launcher)
    '/gz sim'
    'gz-sim-server'
    'gz-sim-gui'
    # Ignition (transitional)
    'ign gazebo'
    'ign-gazebo-server'
    'ign-gazebo-gui'
    # Old Gazebo binary
    'gazebo '
)

# Names that should NEVER be killed even if cmdline matches a pattern.
# Editors/IDEs/build tools that may have ROS strings in their command line.
SKIP_PATTERNS=(
    '/code'           # vscode
    'vscode-server'
    'codium'
    'jetbrains'
    'clion'
    'pycharm'
    'colcon '
    'rosdep '
    'pip '
    'apt '
    'kill_ros'        # this script itself, in case
    'tail -f'
    'less '
    'man '
    # GNOME / desktop services (some have --spawner flag, totally unrelated)
    'gvfsd'
    'gvfs-'
    'dbus-'
    'systemd'
)

# ---- collect matches ----
declare -A MATCH_PIDS=()           # pid -> "category|cmdline"

scan_patterns() {
    local category=$1; shift
    local patterns=("$@")
    for pat in "${patterns[@]}"; do
        # pgrep -af prints "PID CMDLINE"; -f matches full cmdline
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local pid="${line%% *}"
            local cmd="${line#* }"

            # protected?
            if is_protected "$pid"; then
                [ "$VERBOSE" = "1" ] && echo "${C_DIM}[skip protected $pid] $cmd${C_RST}"
                continue
            fi

            # in skip list?
            local skip=0
            for sp in "${SKIP_PATTERNS[@]}"; do
                if [[ "$cmd" == *"$sp"* ]]; then
                    skip=1
                    [ "$VERBOSE" = "1" ] && echo "${C_DIM}[skip ($sp) $pid] $cmd${C_RST}"
                    break
                fi
            done
            [ "$skip" = "1" ] && continue

            # de-dup
            if [ -z "${MATCH_PIDS[$pid]:-}" ]; then
                MATCH_PIDS[$pid]="$category|$cmd"
            fi
        done < <(pgrep -af "$pat" 2>/dev/null)
    done
}

echo "${C_CYAN}[scan] looking for ROS 2 / Gazebo leftovers...${C_RST}"
scan_patterns "ROS"    "${ROS_PATTERNS[@]}"
scan_patterns "GAZEBO" "${GAZEBO_PATTERNS[@]}"

# ---- print findings ----
if [ ${#MATCH_PIDS[@]} -eq 0 ]; then
    echo "${C_GREEN}[scan] no matching processes.${C_RST}"
else
    echo
    printf "%-7s %-7s %s\n" "PID" "TYPE" "CMD"
    printf "%-7s %-7s %s\n" "---" "----" "---"
    # Sort PIDs numerically for stable output
    for pid in $(printf '%s\n' "${!MATCH_PIDS[@]}" | sort -n); do
        IFS='|' read -r cat cmd <<< "${MATCH_PIDS[$pid]}"
        # Truncate long cmdline for readability
        cmd_short="${cmd:0:120}"
        [ "${#cmd}" -gt 120 ] && cmd_short="${cmd_short}..."
        printf "%-7s ${C_YELLOW}%-7s${C_RST} %s\n" "$pid" "$cat" "$cmd_short"
    done
    echo
    echo "${C_CYAN}[found] ${#MATCH_PIDS[@]} process(es)${C_RST}"
fi

# ---- dry-run exit ----
if [ "$DRY_RUN" = "1" ]; then
    echo "${C_DIM}[dry-run] not killing anything.${C_RST}"
    [ "$KEEP_SHM" = "0" ] && echo "${C_DIM}[dry-run] would also clean: /dev/shm/fastrtps_*  /dev/shm/sem.fastrtps_* /dev/shm/iceoryx_* /tmp/.gz* /tmp/.ignition${C_RST}"
    exit 0
fi

# ---- confirm ----
if [ ${#MATCH_PIDS[@]} -gt 0 ] && [ "$ASSUME_YES" = "0" ]; then
    read -rp "Kill these ${#MATCH_PIDS[@]} process(es)? [y/N] " ans
    case "${ans,,}" in
        y|yes) ;;
        *)
            echo "Aborted."
            exit 1
            ;;
    esac
fi

# ---- staged kill: INT -> TERM -> KILL ----
kill_stage() {
    local sig=$1
    local wait_s=$2
    local stage_label=$3
    local survivors=()

    if [ ${#MATCH_PIDS[@]} -eq 0 ]; then
        return
    fi

    echo "${C_CYAN}[$stage_label] sending SIG$sig to ${#MATCH_PIDS[@]} pid(s)...${C_RST}"
    for pid in "${!MATCH_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "-$sig" "$pid" 2>/dev/null || true
        fi
    done

    # Wait, then prune dead ones
    sleep "$wait_s"
    for pid in "${!MATCH_PIDS[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            unset 'MATCH_PIDS[$pid]'
        else
            survivors+=("$pid")
        fi
    done
    echo "${C_DIM}  -> ${#survivors[@]} survivor(s) after SIG$sig${C_RST}"
}

if [ ${#MATCH_PIDS[@]} -gt 0 ]; then
    kill_stage INT  5 "stage 1/3"
    kill_stage TERM 3 "stage 2/3"
    kill_stage KILL 1 "stage 3/3"

    if [ ${#MATCH_PIDS[@]} -gt 0 ]; then
        echo "${C_RED}[warn] still alive after SIGKILL (likely stuck in kernel):${C_RST}"
        for pid in "${!MATCH_PIDS[@]}"; do
            echo "  pid=$pid  $(ps -o cmd= -p "$pid" 2>/dev/null || echo '<gone>')"
        done
    else
        echo "${C_GREEN}[ok] all matched processes terminated.${C_RST}"
    fi
fi

# ---- ros2 daemon ----
if command -v ros2 >/dev/null 2>&1; then
    echo "${C_CYAN}[ros2] stopping daemon...${C_RST}"
    ros2 daemon stop >/dev/null 2>&1 || true
fi

# ---- shared memory cleanup ----
if [ "$KEEP_SHM" = "0" ]; then
    echo "${C_CYAN}[shm] cleaning DDS shared memory + Gazebo IPC...${C_RST}"

    # Fast DDS / iceoryx shared memory files
    shopt -s nullglob
    shm_files=( /dev/shm/fastrtps_* /dev/shm/sem.fastrtps_* /dev/shm/iceoryx_* /dev/shm/sem.iceoryx_* )
    if [ ${#shm_files[@]} -gt 0 ]; then
        rm -f "${shm_files[@]}" 2>/dev/null && \
            echo "${C_DIM}  removed ${#shm_files[@]} /dev/shm file(s)${C_RST}"
    else
        echo "${C_DIM}  /dev/shm: nothing to clean${C_RST}"
    fi

    # Gazebo / Ignition runtime dirs (per-user)
    for d in /tmp/.gazebo /tmp/.ignition /tmp/.gz; do
        if [ -d "$d" ] && [ -O "$d" ]; then
            rm -rf "$d" 2>/dev/null && echo "${C_DIM}  removed $d${C_RST}"
        fi
    done
    shopt -u nullglob

    # Cyclone DDS may leave SysV semaphores (rare)
    if command -v ipcs >/dev/null 2>&1; then
        # Only remove ones owned by current user
        ipcs -s | awk -v u="$(whoami)" '$3==u {print $2}' | while read -r semid; do
            ipcrm -s "$semid" 2>/dev/null && echo "${C_DIM}  removed sem id=$semid${C_RST}"
        done
    fi
fi

echo "${C_GREEN}[done]${C_RST}"
