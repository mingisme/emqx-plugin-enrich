#!/usr/bin/env python3
"""Subscribes to plant/+/telemetry and prints received messages."""

import paho.mqtt.client as mqtt

BROKER = "emqx"
PORT = 1883


def on_message(client, userdata, msg):
    print(f"[{msg.topic}] {msg.payload.decode()}", flush=True)


def main():
    client = mqtt.Client()
    client.on_message = on_message
    client.connect(BROKER, PORT, 60)
    client.subscribe("plant/+/telemetry")
    print("subscribed to plant/+/telemetry", flush=True)
    client.loop_forever()


if __name__ == "__main__":
    main()