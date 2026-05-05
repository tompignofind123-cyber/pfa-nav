#!/usr/bin/env python3
# Copyright 2025
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

"""Publish a prior PCD map as sensor_msgs/PointCloud2 on `prior_map` topic.

Designed to be visualized as a static reference map (e.g. blue point cloud) in
RViz alongside live SLAM/odom data. Loads the file once on startup, then
republishes the same message at a configurable rate so that late subscribers
(e.g. RViz launched after this node) still receive the data without needing
TRANSIENT_LOCAL durability.

Parameters
----------
file_name : str
    Absolute path to a binary PCD file.
frame_id : str
    Header frame_id used in published PointCloud2 messages.
publish_period_sec : float
    Period (s) between successive publishes. Default 1.0.
"""

import struct
import sys

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import PointCloud2, PointField


_NP_TO_ROS = {
    ("F", 4): PointField.FLOAT32,
    ("F", 8): PointField.FLOAT64,
    ("U", 1): PointField.UINT8,
    ("U", 2): PointField.UINT16,
    ("U", 4): PointField.UINT32,
    ("I", 1): PointField.INT8,
    ("I", 2): PointField.INT16,
    ("I", 4): PointField.INT32,
}

_NP_DTYPE = {
    ("F", 4): "<f4",
    ("F", 8): "<f8",
    ("U", 1): "<u1",
    ("U", 2): "<u2",
    ("U", 4): "<u4",
    ("I", 1): "<i1",
    ("I", 2): "<i2",
    ("I", 4): "<i4",
}


def _parse_pcd_header(f):
    header = {}
    raw_lines = []
    while True:
        line = f.readline()
        if not line:
            raise IOError("Unexpected EOF while reading PCD header")
        raw_lines.append(line)
        text = line.decode("ascii", errors="replace").strip()
        if not text or text.startswith("#"):
            continue
        if " " in text:
            key, value = text.split(None, 1)
        else:
            key, value = text, ""
        header[key] = value
        if key == "DATA":
            break
    return header, raw_lines


def load_binary_pcd(path):
    """Read a binary PCD file and return (numpy array, fields, sizes, types, counts)."""
    with open(path, "rb") as f:
        header, _ = _parse_pcd_header(f)
        fmt = header.get("DATA", "ascii")
        if fmt != "binary":
            raise ValueError(
                f"Only DATA binary supported, got '{fmt}'. File: {path}"
            )
        fields = header["FIELDS"].split()
        sizes = [int(s) for s in header["SIZE"].split()]
        types = [t for t in header["TYPE"].split()]
        counts = [int(c) for c in header["COUNT"].split()]
        n_points = int(header.get("POINTS", header.get("WIDTH", "0")))
        if not (len(fields) == len(sizes) == len(types) == len(counts)):
            raise ValueError("Inconsistent FIELDS/SIZE/TYPE/COUNT in PCD header")

        # Build a numpy structured dtype that matches the on-disk layout.
        np_dtype_specs = []
        for i, name in enumerate(fields):
            key = (types[i], sizes[i])
            if key not in _NP_DTYPE:
                raise ValueError(f"Unsupported field type {types[i]}{sizes[i]} for '{name}'")
            if counts[i] == 1:
                np_dtype_specs.append((name, _NP_DTYPE[key]))
            else:
                np_dtype_specs.append((name, _NP_DTYPE[key], counts[i]))
        dtype = np.dtype(np_dtype_specs)

        # Read remaining bytes as the point array.
        raw = f.read()
        expected = dtype.itemsize * n_points
        if len(raw) < expected:
            raise IOError(
                f"PCD body truncated: expected {expected} bytes, got {len(raw)}"
            )
        # Use only `n_points` rows even if file has trailing padding.
        arr = np.frombuffer(raw[:expected], dtype=dtype)
    return arr, fields, sizes, types, counts


def build_pointcloud2_msg(arr, fields, sizes, types, counts, frame_id):
    msg = PointCloud2()
    msg.header.frame_id = frame_id
    msg.height = 1
    msg.width = int(arr.shape[0])
    msg.is_bigendian = False
    msg.is_dense = True

    offset = 0
    for i, name in enumerate(fields):
        pf = PointField()
        pf.name = name
        pf.offset = offset
        pf.datatype = _NP_TO_ROS[(types[i], sizes[i])]
        pf.count = counts[i]
        msg.fields.append(pf)
        offset += sizes[i] * counts[i]

    msg.point_step = offset
    msg.row_step = msg.point_step * msg.width
    msg.data = arr.tobytes()
    return msg


class PriorPCDPublisher(Node):
    def __init__(self):
        super().__init__("prior_pcd_publisher")

        self.declare_parameter("file_name", "")
        self.declare_parameter("frame_id", "map")
        self.declare_parameter("publish_period_sec", 1.0)

        file_name = (
            self.get_parameter("file_name").get_parameter_value().string_value
        )
        frame_id = self.get_parameter("frame_id").get_parameter_value().string_value
        period = (
            self.get_parameter("publish_period_sec").get_parameter_value().double_value
        )

        if not file_name:
            self.get_logger().error("Parameter 'file_name' is required")
            raise SystemExit(2)

        self.get_logger().info(f"Loading prior PCD: {file_name}")
        try:
            arr, fields, sizes, types, counts = load_binary_pcd(file_name)
        except Exception as exc:  # noqa: BLE001
            self.get_logger().error(f"Failed to load PCD: {exc}")
            raise SystemExit(3) from exc

        self.cloud_msg = build_pointcloud2_msg(
            arr, fields, sizes, types, counts, frame_id
        )
        self.get_logger().info(
            f"Loaded {self.cloud_msg.width} points, fields={fields}, "
            f"point_step={self.cloud_msg.point_step}, frame_id='{frame_id}'"
        )

        # Match RViz default (Volatile, Reliable, depth 1) so any reasonable
        # subscriber QoS will be compatible.
        qos = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.VOLATILE,
            depth=1,
        )
        self.pub = self.create_publisher(PointCloud2, "prior_map", qos)
        self.timer = self.create_timer(max(period, 0.05), self._tick)
        self.get_logger().info(
            f"Publishing on '{self.get_namespace().rstrip('/')}/prior_map' "
            f"every {period:.2f}s (frame_id='{frame_id}')"
        )

    def _tick(self):
        self.cloud_msg.header.stamp = self.get_clock().now().to_msg()
        self.pub.publish(self.cloud_msg)


def main():
    rclpy.init(args=sys.argv)
    try:
        node = PriorPCDPublisher()
    except SystemExit as exc:
        rclpy.shutdown()
        sys.exit(exc.code if exc.code is not None else 1)

    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
