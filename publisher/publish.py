#!/usr/bin/env python3
"""Publishes test messages to plant/+/telemetry."""

import json
import time

import paho.mqtt.client as mqtt

BROKER = "emqx"
PORT = 1883


def main():
    client = mqtt.Client()
    client.connect(BROKER, PORT, 60)

    # dev-001 appears twice so the second message exercises the cache-hit path.
    devices = ["dev-001", "dev-001", "dev-002", "dev-003", "dev-999"]

    for i, dev_id in enumerate(devices):
        topic = f"plant/{dev_id}/telemetry"
        payload = json.dumps({
            "device_id": dev_id,
            "temp_c": 21.5 + i * 0.1,
            "ts": int(time.time()),
        })
        client.publish(topic, payload)
        print(f"published: topic={topic} payload={payload}", flush=True)
        time.sleep(0.5)

    client.disconnect()


if __name__ == "__main__":
    main()