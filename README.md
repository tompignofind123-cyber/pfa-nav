# pfa-nav-main

> 整体框架使用北极熊导航!派大星恩情还不完!

---

## 目录

- [一键脚本总览](#一键脚本总览)
- [4 种使用场景](#4-种使用场景)
  - [场景 1:仿真 + 建图](#场景-1仿真--建图)
  - [场景 2:仿真 + 纯导航(已建图)](#场景-2仿真--纯导航已建图)
  - [场景 3:实车 + 建图](#场景-3实车--建图)
  - [场景 4:实车 + 纯导航(已建图)](#场景-4实车--纯导航已建图)
- [脚本详解](#脚本详解)
  - [slam.sh](#slamsh)
  - [nav.sh](#navsh)
  - [save.sh / save_map_timestamp.sh](#savesh--save_map_timestampsh)
  - [kill_ros.sh](#kill_rossh)
  - [build.sh](#buildsh)
- [工具脚本](#工具脚本)
  - [hero_to_sentry_map_converter.py(英雄图 → 哨兵图)](#hero_to_sentry_map_converterpy英雄图--哨兵图)
- [首次部署](#首次部署)
  - [编译](#编译)
  - [依赖安装](#依赖安装)
  - [源码同步](#源码同步)
- [实车配置](#实车配置)
  - [IMU gravity 标定](#imu-gravity-标定)
  - [雷达姿态(xacro RPY)](#雷达姿态xacro-rpy)
  - [其他需要改的地方](#其他需要改的地方)
- [bag 录制 / 播放](#bag-录制--播放)
- [航点设置 & 比赛逻辑](#航点设置--比赛逻辑)
- [LIO 调参](#lio-调参)
- [常见问题与排错](#常见问题与排错)

---

## 一键脚本总览

项目根目录提供以下脚本,跨机器可移植(全部相对路径,自动 `cd` 到脚本所在目录):

| 脚本 | 作用 | 典型调用 |
|------|------|----------|
| `slam.sh` | 启动 SLAM 建图(仿真/实车通用),Ctrl+C 时安全保存 PCD/2D 地图/rosbag,自动带时间戳备份 | `./slam.sh world:=rmuc_2026` |
| `nav.sh` | 启动纯导航(已建好图),Ctrl+C 安全退出 | `./nav.sh` |
| `save.sh` | 手动一次性保存 2D 地图为 `game.yaml/pgm` | `./save.sh` |
| `save_map_timestamp.sh` | 带时间戳保存 2D 地图,不覆盖 | `./save_map_timestamp.sh` |
| `kill_ros.sh` | 一键清理 ROS 2 / Gazebo 残留进程 + DDS 共享内存 | `./kill_ros.sh -y` |
| `build.sh` | 限并发编译并启动实车建图(包装) | `./build.sh` |
| `hero_to_sentry_map_converter.py` | 把"用某种雷达姿态建好的地图"旋转成"另一种姿态"对应的地图,无需重建 | `python3 hero_to_sentry_map_converter.py` |

> 第一次用先 `chmod +x *.sh`,所有脚本都用 `SCRIPT_DIR` 自适应当前路径,**直接拷到任何机器/任何路径都能跑**(前提是目录里有完整 `install/`)。

---

## 4 种使用场景

> 共同前置:每个新终端先 source 环境
> ```bash
> cd ~/pfa-nav-main
> source /opt/ros/humble/setup.bash
> source install/setup.bash
> ```

### 场景 1:仿真 + 建图

**用途**:在 Gazebo 里建图,得到 2D 栅格 + 3D 点云。

```bash
# 终端 1:启 Gazebo(启动后点左下角橙红色"启动"按钮)
ros2 launch rmu_gazebo_simulator bringup_sim.launch.py world:=rmuc_2026

# 终端 2:启 SLAM(用脚本,Ctrl+C 安全落盘 + 自动备份)
./slam.sh --no-bag world:=rmuc_2026 \
    auto_save_map:=True \
    auto_save_map_interval:=20.0
```

**说明**
- `--no-bag`:仿真时跳过 rosbag 录制(实车需要数据回放再去掉这个开关)
- `slam:=True`:由 `slam.sh` 内部固定带上,会同时打开 `point_lio.pcd_save_en`
- `auto_save_map:=True` + `auto_save_map_interval:=20.0`:每 20s 自动保存 2D 地图(yaml+pgm)
- Ctrl+C 一次后,脚本会:
  1. 立刻 `SIGINT` 给 launch → `point_lio` 走完 `main()` 末尾 `writeBinary` 写 PCD
  2. 同时调 `map_saver` 保存 2D 地图(超时 15s 兜底)
  3. 等待 PCD mtime 更新(最多 60s),验证落盘
  4. 自动 `cp scans.pcd scans_<时间戳>.pcd` 备份
- 看到 `[slam.sh] PCD updated:` 就成功;若 `WARNING: PCD mtime did not update`,把 `slam.sh` 里 `sigterm_timeout:=30` 调到 60 或更大

**控车测试(可选)**
```bash
ros2 run rmoss_gz_base test_chassis_cmd.py \
    --ros-args -r __ns:=/red_standard_robot1/robot_base \
    -p v:=5.0 -p w:=0.3
```

**手动多保存一份 2D 地图(可选)**
```bash
./save_map_timestamp.sh   # 输出 src/.../map/simulation/auto_map_<时间戳>.{pgm,yaml}
```

---

### 场景 2:仿真 + 纯导航(已建图)

**前置**:已经在场景 1 跑过 SLAM,`scans.pcd` 和栅格地图已生成。

```bash
# 终端 1:启 Gazebo
ros2 launch rmu_gazebo_simulator bringup_sim.launch.py world:=rmuc_2026

# 终端 2:纯导航
ros2 launch pb2025_nav_bringup rm_navigation_simulation_launch.py \
    world:=rmuc_2026 slam:=False
```

> 仿真+导航用的还是原生 launch,不走 `nav.sh`(`nav.sh` 是给实车的)。

---

### 场景 3:实车 + 建图

```bash
./slam.sh world:=rmuc_2026 \
    auto_save_map:=True \
    auto_save_map_interval:=20.0
```

> 实车**不要**加 `--no-bag` —— 录 rosbag 能在事故后回放调试。bag 默认存到 `src/pb2025_sentry_nav/point_lio/PCD/slam_bag_<时间戳>/`。

Ctrl+C 后会拿到:
- `src/.../point_lio/PCD/scans.pcd`(最新,会被下次覆盖)
- `src/.../point_lio/PCD/scans_<时间戳>.pcd`(自动备份)
- `src/.../point_lio/PCD/<map_name>.pgm/.yaml`(2D 栅格地图)
- `src/.../point_lio/PCD/slam_bag_<时间戳>/`(rosbag)

**手动保存一份方便接力使用**
```bash
./save.sh   # 把当前 2D 地图保存为 game.yaml/pgm,同时拷到 reality/ 和 simulation/ 两个目录
```

---

### 场景 4:实车 + 纯导航(已建图)

```bash
./nav.sh
```

`nav.sh` 内部做了:
1. 自动把 `src/.../point_lio/PCD/scans.pcd` 拷成 `src/.../pb2025_nav_bringup/pcd/reality/game.pcd` 作为先验点云
2. 启动 `rm_navigation_reality_launch.py world:=game slam:=False use_robot_state_pub:=True`
3. Ctrl+C 时 SIGINT 给 launch + 等 PCD 落盘验证 + 时间戳备份(若 `pcd_save_en=True`)

> `localization_launch.py` 已在第 129 行写死 `pcd_save.pcd_save_en: True`,所以纯导航模式也会写一份 PCD,适合在实车场景持续记录。

启动后**记得在 RViz 发一次 `2D Pose Estimate`**,加快 GICP 重定位收敛。

---

## 脚本详解

### `slam.sh`

```
./slam.sh [--no-bag] [extra launch args...]
```

**功能**:启动 `rm_navigation_simulation_launch.py slam:=True`,Ctrl+C 时安全落盘 PCD + 2D 地图 + rosbag。

| 参数 | 作用 |
|------|------|
| `--no-bag` | 跳过 rosbag 录制(仿真常用) |
| 其他 `key:=value` | 直接透传给 ros2 launch(如 `world:=rmuc_2026`、`auto_save_map:=True`) |

**关键设计**(为什么 Ctrl+C 能稳定保存):
1. `setsid` 把 launch 隔离到独立进程组
2. trap 接 Ctrl+C,先 `SIGINT` 给 launch(让 `point_lio` 走完 `main()` 末尾 `writeBinary`)
3. 通过 launch 参数 `sigterm_timeout:=30 sigkill_timeout:=60` 拉长 grace 期
4. `trap '' SIGINT SIGTERM` 防重入(用户连按 Ctrl+C 不会打断 cleanup)
5. 落盘验证:轮询 `scans.pcd` 的 mtime,确保大于 cleanup 开始时间
6. 验证后自动 `cp scans.pcd scans_<时间戳>.pcd`

### `nav.sh`

```
./nav.sh [extra launch args...]
```

**功能**:启动实车纯导航(已建图),拷贝先验 PCD,Ctrl+C 安全退出。

跟 `slam.sh` 用同一套 cleanup 框架(trap、sigterm_timeout、落盘验证、时间戳备份)。

### `save.sh` / `save_map_timestamp.sh`

| 脚本 | 输出 | 用途 |
|------|------|------|
| `save.sh` | `src/.../map/reality/game.{pgm,yaml}` 和 `src/.../map/simulation/game.{pgm,yaml}` | 一次性保存当前 2D 地图为 game(会覆盖) |
| `save_map_timestamp.sh` | `src/.../map/simulation/auto_map_<时间戳>.{pgm,yaml}` | 带时间戳保存,不覆盖,适合多次备份 |

### `kill_ros.sh`

```
./kill_ros.sh             # 列清单 → y/n 确认 → INT→TERM→KILL 三阶段杀
./kill_ros.sh -y          # 跳过确认
./kill_ros.sh -n          # dry-run,只列出不杀
./kill_ros.sh --keep-shm  # 不清 /dev/shm/*
./kill_ros.sh -v          # verbose:打印每个 skip / protected 决定
./kill_ros.sh -h          # 帮助
```

**做什么**
- 扫描 ROS 2 / Gazebo 残留(`parameter_bridge`、`nav2_*`、`point_lio`、`gzserver`、`gz sim`、`rmu_gazebo_*`、`pb2025_*` 等)
- 三阶段杀:`SIGINT`(5s 让 trap 落盘)→ `SIGTERM`(3s)→ `SIGKILL`
- `ros2 daemon stop`
- 清 `/dev/shm/fastrtps_*` / `iceoryx_*` / `/tmp/.gazebo` / `/tmp/.ignition`

**安全保护**
- 永不杀:自身 PID + 父 shell 全祖先链
- 跳过白名单:`code` / `vscode-server` / `jetbrains` / `clion` / `pycharm` / `colcon` / `rosdep` / `dbus-` / `gvfsd` / `systemd`

**典型用法**:仿真崩了/Ctrl+C 没干净退出 →
```bash
./kill_ros.sh -y && ./slam.sh ...
```

### `build.sh`

带限并发的编译包装(2 核,避免内存占满卡死)。当前默认进入实车建图,需要的话改一下里面的命令。

```bash
./build.sh
# 等价于:
# colcon build --symlink-install --parallel-workers 2 --cmake-args -DCMAKE_BUILD_TYPE=Release
# source install/setup.bash
# ros2 launch pb2025_nav_bringup rm_navigation_reality_launch.py slam:=True use_robot_state_pub:=True
```

---

## 工具脚本

### `hero_to_sentry_map_converter.py`(英雄图 → 哨兵图)

把"用某种雷达姿态建好的地图"旋转成"另一种姿态"对应的地图,**不用重新建图**。

**典型场景**:雷达从平躺装(`pose="x y z 0 0 pi"`)改成竖立装(`pose="x y z 0 -pi/2 pi"`),旧地图直接复用。

**3 种输入模式**

| 模式 | 适用 | 例 |
|------|------|----|
| `rpy`(推荐) | 直接抄 xacro `pose=` 后 3 个数 | `0 0 pi` 和 `0 -pi/2 pi` |
| `forward_gravity` | map 系下"前向 + 重力"两个独立向量 | `1,0,0` + `0,0,-1` |
| `gravity_yaw` | 只有 IMU 标定的 `gravity_init` + yaw | `0,-4.9,-8.487` + `pi` |

**最简单的用法**
```bash
python3 hero_to_sentry_map_converter.py
# 交互模式:回车走默认 → 选 1)RPY → 输入 RPY → 完成
```

**详细文档**:见 [`HERO_MAP_CONVERTER_README.md`](./HERO_MAP_CONVERTER_README.md)(完整 426 行手册,包含工作原理、CLI 参数表、FAQ、排错)

---

## 首次部署

### 编译

```bash
colcon build --symlink-install --parallel-workers 2 \
    --cmake-args -DCMAKE_BUILD_TYPE=Release
```

> 内存 < 16GB 的机器建议 `--parallel-workers 2`,避免卡死。

### 依赖安装

```bash
# ROS 依赖
rosdep install -r --from-paths src --ignore-src --rosdistro $ROS_DISTRO -y
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH

# 系统依赖
sudo apt install -y libeigen3-dev libomp-dev git-lfs ros-humble-joint-state-publisher \
                    ros-humble-serial-driver \
                    libopencv-dev python3-pytest cmake libgoogle-glog-dev libapr1-dev \
                    libignition-transport11-dev

# Python 工具
sudo pip install vcstool2
pip install xmacro jinja2 typeguard

# small_gicp 编译安装
cd small_gicp
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j
sudo make install
cd -
```

### 源码同步

```bash
git clone https://github.com/SMBU-PolarBear-Robotics-Team/rmu_gazebo_simulator.git \
    src/rmu_gazebo_simulator
vcs import src < src/rmu_gazebo_simulator/dependencies.repos
rosdep install -r --from-paths src --ignore-src --rosdistro $ROS_DISTRO -y
```

---

## 实车配置

### IMU gravity 标定

文件:`src/pb2025_nav_bringup/config/reality/nav2_params.yaml`(里面 `gravity` / `gravity_init` 字段)

**步骤**:

1. 启动雷达驱动:
   ```bash
   ros2 launch livox_ros_driver2 msg_MID360_launch.py
   ```
2. 新终端订阅 IMU:
   ```bash
   ros2 topic echo /livox/imu
   ```
3. 取静止状态下 `linear_acceleration` 的 (x,y,z),**加负号**写入 `gravity` / `gravity_init`

例:雷达静止时 IMU 读到 `(0, 4.9, 8.487)` →
```yaml
gravity:      [0.0, -4.9, -8.487047153776548]
gravity_init: [0.0, -4.9, -8.487047153776548]
```

### 雷达姿态(xacro RPY)

文件:对应机器人的 xacro,例如 `pose="x y z R P Y"`:

```xml
<!-- 平躺 -->
<xmacro_block name="livox" prefix="front_" parent="chassis"
              pose="0.16 0.0 0.18  0 0 ${pi}" update_rate="10" samples="400"/>

<!-- 竖立向前 -->
<xmacro_block name="livox" prefix="front_" parent="chassis"
              pose="0.16 0.0 0.18  0 -${pi/2} ${pi}" update_rate="10" samples="400"/>
```

> 改了 RPY 必须同时改 yaml 里的 `gravity` / `gravity_init` —— 这两个表达的是同一个物理事实。
> 已建好的图不想重建?用 [hero_to_sentry_map_converter.py](#hero_to_sentry_map_converterpy英雄图--哨兵图) 旋转旧图。

### 其他需要改的地方

- `src/pb2025_nav_bringup/config/reality/mid360_user_config.json`:Mid360 用户配置,实车 IP 等
- 详见图示:`images/image1.png` ~ `image4.png`

---

## bag 录制 / 播放

**录制**

```bash
# 仿真(带 namespace)
ros2 bag record /red_standard_robot1/livox/lidar /red_standard_robot1/livox/imu \
                /red_standard_robot1/tf /red_standard_robot1/tf_static \
                -o ~/sight/pfa-nav/bag

# 仿真精简版(只录雷达 + IMU)
ros2 bag record /red_standard_robot1/livox/lidar /red_standard_robot1/livox/imu \
                -o ~/sight/pfa-nav/bag

# 实车
ros2 bag record /livox/lidar /livox/imu -o ~/sight/pfa-nav/bag

# 列话题
ros2 topic list
```

**播放**

```bash
ros2 bag play ~/sight/pfa-nav/bag                  # 默认速率
ros2 bag play ~/sight/pfa-nav/bag --rate 1.5       # 1.5 倍
ros2 bag play ~/sight/pfa-nav/bag --topic /livox/imu  # 只回放某话题
ros2 bag play bag/bag_0.db3 --clock                # 用 bag 自带时钟
```

**用 bag 测试导航**

```bash
ros2 launch pb2025_nav_bringup rm_navigation_simulation_launch.py \
    world:=game slam:=False use_sim_time:=True
ros2 bag play bag/bag_0.db3 --clock
# 新终端发 map → front_mid360 静态 TF
ros2 run tf2_ros static_transform_publisher 0 0 0 0 0 0 map front_mid360
```

---

## 航点设置 & 比赛逻辑

**安装 wp_map_tools**
```bash
git clone https://github.com/6-robot/wp_map_tools.git
cd wp_map_tools/scripts
./install_for_humble.sh
cd ..
source install/setup.bash
```

**添加航点**

| 模式 | 命令 | 备注 |
|------|------|------|
| 实车 | `ros2 launch wp_map_tools add_waypoint_reality.launch.py` | 改 `launch/add_waypoint_reality.launch.py` 里的目录 |
| 仿真 | `ros2 launch wp_map_tools add_waypoint_simulation.launch.py` | 改 `game.py` 里的 `self.nav_ac = ActionClient(self, NavigateToPose, '/red_standard_robot1/navigate_to_pose')` |

**保存航点**
```bash
ros2 run wp_map_tools wp_saver       # 改 src/wp_saver.cpp 里的目录
```

**实车比赛**
```bash
python3 game.py --home 1 --guard 4 --order 1 3 5            # 指定循环点 + 家 + 巡逻点
python3 game.py --home 1 --guard 1 --order 1 2 3 --force_loop  # 强制循环
python3 send.py                                              # 单纯发 vx,vy
```

**串口数据格式**
```
S{x_sign}{x_vel:03d}{y_sign}{y_vel:03d}{status_flag}E
```

---

## LIO 调参

整理自 point_lio 各 Issue:

- 室内场景把 `filter_size_surf`、`filter_size_map` 调小:常用 `0.05` / `0.15`
- Ouster 这种点特别密的雷达,`point_filter_num` 可调到 `5~10`
- 点云密集 → 调大 `lidar_meas_cov`
- 结构单一(走廊、空地) → 调大 `lidar_meas_cov`

---

## 常见问题与排错

### 编译卡死(内存爆炸)
```bash
colcon build --symlink-install --parallel-workers 2 --cmake-args -DCMAKE_BUILD_TYPE=Release
```

### `serial_driver/serial_driver.hpp` 找不到
```bash
sudo apt update && sudo apt install ros-humble-serial-driver
```

### `point_lio` 起不来:libusb 版本冲突

```bash
LD_PRELOAD=/lib/x86_64-linux-gnu/libusb-1.0.so.0 ros2 launch point_lio point_lio.launch.py
```

或者写进 `install/local_setup.bash` 末尾:
```bash
export LD_PRELOAD=/lib/x86_64-linux-gnu/libusb-1.0.so.0
```

之后 `source install/setup.bash` 自动带 preload。

### `msg_MID360_launch.py` 跑不通(找不到 `liblivox_lidar_sdk_shared.so`)
```bash
cd livox_lidar_sdk
mkdir build && cd build
cmake .. && make -j4
sudo make install
sudo ldconfig
ls /usr/local/lib | grep liblivox_lidar_sdk_shared.so   # 验证存在
```

### Gazebo / Ignition 软件源损坏(`libignition-transport11`)
```bash
sudo rm -f /etc/apt/sources.list.d/gazebo-stable.list
sudo rm -f /etc/apt/keyrings/gazebo.gpg
sudo rm -f /usr/share/keyrings/gazebo-archive-keyring.gpg
sudo mkdir -p /usr/share/keyrings
curl -fsSL https://packages.osrfoundation.org/gazebo.key \
  | sudo gpg --dearmor -o /usr/share/keyrings/gazebo-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/gazebo-archive-keyring.gpg] https://packages.osrfoundation.org/gazebo/ubuntu jammy main" \
  | sudo tee /etc/apt/sources.list.d/gazebo-stable.list > /dev/null
sudo apt update
sudo apt install ros-humble-ros-gz-bridge ros-humble-ros-gz-sim libignition-transport11-dev -y
```

### `libignition-gazebo6`
```bash
sudo apt install libignition-gazebo6-dev
```

### Gazebo 启动报错 / 上次没干净退出
```bash
./kill_ros.sh -y     # 一键清,见上面 kill_ros.sh 节
```

> 老办法是手动 `kill -9 <gazebo-server PID>`,现在直接用脚本。

### TF_OLD_DATA 警告 `gimbal_yaw_fake`
仿真启动后短暂出现是正常的(TF 缓冲与时钟对齐期间)。如果持续刷,检查 `use_sim_time` 是否一致。

### RViz 不能连 X11(`Maximum number of clients reached` / `qt.qpa.xcb: could not connect to display :1`)
```bash
xdpyinfo -display :1 >/dev/null && echo OK || echo BAD
# BAD 的话,关掉占用 X 的程序(QQ、其他 RViz 实例),再试
```

### 想看带 namespace 的 TF tree
```bash
ros2 run rqt_tf_tree rqt_tf_tree \
    --ros-args -r /tf:=tf -r /tf_static:=tf_static -r __ns:=/red_standard_robot1
```

### 精修栅格地图(GIMP,可选)
- 安装:https://www.gimp.org/
- 用橡皮擦工具擦除噪点;画笔加围挡;另存为 `.pgm`

---

## 项目设计:namespace

本项目所有 node、topic、action 都加了 namespace 前缀(`/red_standard_robot1/...`)。涉及订阅外部话题时记得加 remap,例如 `--ros-args -r __ns:=/red_standard_robot1`。

---

![alt text](images/image.png)
![alt text](images/image1.png)
![alt text](images/image2.png)
![alt text](images/image3.png)
![alt text](images/image4.png)
