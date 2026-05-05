#!/usr/bin/env python3
"""Export a versioned map bundle for cross-robot reuse.

The bundle includes:
- latest auto_map_*.yaml and its paired image file
- point_lio scans.pcd

Output layout:
<output_root>/map_bundle_<timestamp>/
  map.yaml
  map.pgm
  scans.pcd
  metadata.txt
"""

from __future__ import annotations

import argparse
import shutil
from datetime import datetime
from pathlib import Path


def find_latest_auto_map(map_dir: Path) -> Path:
    candidates = sorted(map_dir.glob("auto_map_*.yaml"))
    if not candidates:
        raise FileNotFoundError(f"No auto_map_*.yaml found in {map_dir}")
    return candidates[-1]


def resolve_map_image(yaml_path: Path) -> Path:
    image_field = None
    for line in yaml_path.read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("image:"):
            image_field = line.split(":", 1)[1].strip()
            break

    if not image_field:
        fallback = yaml_path.with_suffix(".pgm")
        if fallback.exists():
            return fallback
        raise FileNotFoundError(f"Cannot resolve map image for {yaml_path}")

    image_path = (yaml_path.parent / image_field).resolve()
    if image_path.exists():
        return image_path

    fallback = yaml_path.with_suffix(".pgm")
    if fallback.exists():
        return fallback
    raise FileNotFoundError(f"Map image does not exist: {image_path}")


def export_bundle(map_dir: Path, pcd_file: Path, output_root: Path, bundle_name: str | None) -> Path:
    latest_yaml = find_latest_auto_map(map_dir)
    map_image = resolve_map_image(latest_yaml)

    if not pcd_file.exists() or pcd_file.stat().st_size == 0:
        raise FileNotFoundError(f"PCD file missing or empty: {pcd_file}")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    bundle_dir_name = bundle_name or f"map_bundle_{timestamp}"
    bundle_dir = output_root / bundle_dir_name
    bundle_dir.mkdir(parents=True, exist_ok=False)

    target_yaml = bundle_dir / "map.yaml"
    target_image = bundle_dir / f"map{map_image.suffix}"
    target_pcd = bundle_dir / "scans.pcd"

    shutil.copy2(latest_yaml, target_yaml)
    shutil.copy2(map_image, target_image)
    shutil.copy2(pcd_file, target_pcd)

    yaml_lines = target_yaml.read_text(encoding="utf-8").splitlines()
    rewritten = []
    replaced = False
    for line in yaml_lines:
        if line.strip().startswith("image:"):
            rewritten.append(f"image: {target_image.name}")
            replaced = True
        else:
            rewritten.append(line)

    if not replaced:
        rewritten.append(f"image: {target_image.name}")

    target_yaml.write_text("\n".join(rewritten) + "\n", encoding="utf-8")

    metadata = (
        f"exported_at: {datetime.now().isoformat()}\n"
        f"source_yaml: {latest_yaml}\n"
        f"source_image: {map_image}\n"
        f"source_pcd: {pcd_file}\n"
        f"robot2_launch_example: ros2 launch pb2025_nav_bringup rm_navigation_simulation_launch.py "
        f"slam:=False map:={target_yaml} prior_pcd_file:={target_pcd}\n"
    )
    (bundle_dir / "metadata.txt").write_text(metadata, encoding="utf-8")

    return bundle_dir


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export a versioned map bundle")
    parser.add_argument(
        "--map-dir",
        default="/home/tompig/pfa-nav-main/src/pb2025_sentry_nav/pb2025_nav_bringup/map/simulation",
        help="Directory containing auto_map_*.yaml",
    )
    parser.add_argument(
        "--pcd-file",
        default="/home/tompig/pfa-nav-main/src/pb2025_sentry_nav/point_lio/PCD/scans.pcd",
        help="Prior PCD file path",
    )
    parser.add_argument(
        "--output-root",
        default="/home/tompig/pfa-nav-main/src/pb2025_sentry_nav/pb2025_nav_bringup/map_bundles",
        help="Output root directory",
    )
    parser.add_argument(
        "--bundle-name",
        default="",
        help="Optional bundle directory name",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    bundle = export_bundle(
        map_dir=Path(args.map_dir).resolve(),
        pcd_file=Path(args.pcd_file).resolve(),
        output_root=Path(args.output_root).resolve(),
        bundle_name=args.bundle_name or None,
    )
    print(bundle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
