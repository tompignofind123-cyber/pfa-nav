#!/usr/bin/env python3
import os
from datetime import datetime

import rclpy
from nav2_msgs.srv import SaveMap
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node


class PeriodicMapSaver(Node):
    def __init__(self):
        super().__init__('periodic_map_saver')

        self.declare_parameter('save_interval_sec', 120.0)
        self.declare_parameter('map_dir', '')
        self.declare_parameter('map_topic', 'map')
        self.declare_parameter('image_format', 'pgm')
        self.declare_parameter('map_mode', 'trinary')
        self.declare_parameter('free_thresh', 0.25)
        self.declare_parameter('occupied_thresh', 0.65)
        self.declare_parameter('save_on_shutdown', True)
        self.declare_parameter('shutdown_wait_timeout_sec', 5.0)

        self.save_interval_sec = float(self.get_parameter('save_interval_sec').value)
        map_dir = str(self.get_parameter('map_dir').value)
        self.map_topic = str(self.get_parameter('map_topic').value)
        self.image_format = str(self.get_parameter('image_format').value)
        self.map_mode = str(self.get_parameter('map_mode').value)
        self.free_thresh = float(self.get_parameter('free_thresh').value)
        self.occupied_thresh = float(self.get_parameter('occupied_thresh').value)
        self.save_on_shutdown = bool(self.get_parameter('save_on_shutdown').value)
        self.shutdown_wait_timeout_sec = float(
            self.get_parameter('shutdown_wait_timeout_sec').value
        )

        if not map_dir:
            raise RuntimeError('Parameter map_dir must be set')
        self.map_dir = os.path.abspath(map_dir)
        os.makedirs(self.map_dir, exist_ok=True)

        namespace = self.get_namespace().strip('/')
        self.service_name = f'/{namespace}/map_saver/save_map' if namespace else '/map_saver/save_map'

        self.client = self.create_client(SaveMap, self.service_name)
        self.pending_future = None

        self.timer = self.create_timer(self.save_interval_sec, self._on_timer)
        self.get_logger().info(
            f'Periodic map saver started. interval={self.save_interval_sec}s, '
            f'service={self.service_name}, output_dir={self.map_dir}'
        )

    def _resolve_map_topic(self):
        if not self.map_topic.startswith('/'):
            namespace = self.get_namespace().strip('/')
            return f'/{namespace}/{self.map_topic}' if namespace else f'/{self.map_topic}'
        return self.map_topic

    def _request_save(self, map_url, attach_callback=True):
        if not self.client.wait_for_service(timeout_sec=0.5):
            self.get_logger().warn(f'Service unavailable: {self.service_name}')
            return None

        request = SaveMap.Request()
        request.map_topic = self._resolve_map_topic()
        request.map_url = map_url
        request.image_format = self.image_format
        request.map_mode = self.map_mode
        request.free_thresh = self.free_thresh
        request.occupied_thresh = self.occupied_thresh

        future = self.client.call_async(request)
        if attach_callback:
            future.add_done_callback(lambda done: self._on_response(done, map_url))
        return future

    def _on_timer(self):
        if self.pending_future is not None and not self.pending_future.done():
            self.get_logger().warn('Previous save request still running, skipping this cycle')
            return

        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        map_url = os.path.join(self.map_dir, f'auto_map_{ts}')
        self.pending_future = self._request_save(map_url)

    def _on_response(self, future, map_url):
        try:
            response = future.result()
        except Exception as exc:  # noqa: BLE001
            self.get_logger().error(f'Map save failed: {exc}')
            return

        if response.result:
            self.get_logger().info(
                f'Map saved: {map_url}.{self.image_format} and {map_url}.yaml'
            )
        else:
            self.get_logger().error(f'Map save returned failure for {map_url}')

    def save_once_on_shutdown(self):
        if not self.save_on_shutdown:
            self.get_logger().info('save_on_shutdown disabled, skip final map save')
            return

        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        map_url = os.path.join(self.map_dir, f'final_map_{ts}')
        self.get_logger().info(f'Shutdown save requested: {map_url}')

        future = self._request_save(map_url, attach_callback=False)
        if future is None:
            return

        try:
            rclpy.spin_until_future_complete(
                self,
                future,
                timeout_sec=self.shutdown_wait_timeout_sec,
            )
        except Exception as exc:  # noqa: BLE001
            self.get_logger().error(f'Wait final save result failed: {exc}')
            return

        if not future.done():
            self.get_logger().error(
                f'Final map save timed out after {self.shutdown_wait_timeout_sec}s: {map_url}'
            )
            return

        try:
            response = future.result()
        except Exception as exc:  # noqa: BLE001
            self.get_logger().error(f'Final map save failed: {exc}')
            return

        if response.result:
            self.get_logger().info(
                f'Final map saved: {map_url}.{self.image_format} and {map_url}.yaml'
            )
        else:
            self.get_logger().error(f'Final map save returned failure for {map_url}')


def main():
    rclpy.init()
    node = PeriodicMapSaver()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        # rclpy's default SIGINT handler destroys the rcl context before
        # control reaches this block, which means the final save is normally
        # done by slam.sh BEFORE SIGINT (see cleanup() in slam.sh).
        # Only attempt the in-process final save if the context is still
        # valid (e.g. the script was killed by a non-rclpy signal path).
        pass
    finally:
        if rclpy.ok():
            try:
                node.save_once_on_shutdown()
            except Exception as exc:  # noqa: BLE001
                # Swallow RCLError / any rcl-layer failure during shutdown.
                # The map has already been saved by slam.sh in the normal path.
                try:
                    node.get_logger().warn(f'Skip in-process final save: {exc}')
                except Exception:
                    pass
        try:
            node.destroy_node()
        except Exception:  # noqa: BLE001
            pass
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
