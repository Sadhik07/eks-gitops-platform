"""Order worker: long-polls SQS, processes orders, exposes queue-health metrics.

Failed messages are not deleted, so SQS redelivers them and, after
maxReceiveCount, moves them to the DLQ (configured in Terraform).
"""

from __future__ import annotations

import json
import logging
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Protocol

from prometheus_client import Counter, Gauge, Histogram, start_http_server

log = logging.getLogger("worker")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(message)s")

PROCESSED = Counter("worker_messages_processed_total", "Messages processed", ["result"])
PROCESS_SECONDS = Histogram("worker_process_duration_seconds", "Processing time")
MESSAGE_AGE = Gauge(
    "worker_oldest_message_age_seconds",
    "Age of the oldest message in the last received batch (0 when the queue is empty)",
)
LAST_POLL = Gauge(
    "worker_last_poll_timestamp_seconds", "Unix time of last successful poll"
)


class QueueClient(Protocol):
    def receive(self) -> list[dict[str, Any]]: ...
    def delete(self, receipt_handle: str) -> None: ...


class SqsQueue:
    def __init__(self, url: str) -> None:
        import boto3

        self.url = url
        self.sqs = boto3.client("sqs")

    def receive(self) -> list[dict[str, Any]]:
        resp = self.sqs.receive_message(
            QueueUrl=self.url,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=20,
            MessageSystemAttributeNames=["SentTimestamp"],
        )
        return resp.get("Messages", [])

    def delete(self, receipt_handle: str) -> None:
        self.sqs.delete_message(QueueUrl=self.url, ReceiptHandle=receipt_handle)


def process(order: dict[str, Any]) -> None:
    """Business logic placeholder: validate and 'fulfil' an order."""
    if order.get("quantity", 0) <= 0:
        raise ValueError(f"invalid quantity for order {order.get('id')}")
    time.sleep(float(os.getenv("PROCESS_DELAY_SECONDS", "0.05")))


def handle_batch(queue: QueueClient, now: float | None = None) -> tuple[int, int]:
    ok = failed = 0
    now = now or time.time()
    messages = queue.receive()
    ages = [
        now - int(m.get("Attributes", {}).get("SentTimestamp", now * 1000)) / 1000
        for m in messages
    ]
    MESSAGE_AGE.set(max([0.0, *ages]))  # 0 when the queue is drained
    for msg in messages:
        with PROCESS_SECONDS.time():
            try:
                process(json.loads(msg["Body"]))
            except Exception as exc:  # noqa: BLE001 - leave for redelivery/DLQ
                failed += 1
                PROCESSED.labels("error").inc()
                log.warning(json.dumps({"msg": "processing failed", "error": str(exc)}))
                continue
        queue.delete(msg["ReceiptHandle"])
        ok += 1
        PROCESSED.labels("ok").inc()
    LAST_POLL.set(now)
    return ok, failed


class Health(BaseHTTPRequestHandler):
    max_poll_age = float(os.getenv("MAX_POLL_AGE_SECONDS", "120"))

    def do_GET(self) -> None:  # noqa: N802
        last = LAST_POLL._value.get()  # noqa: SLF001
        healthy = self.path == "/healthz" and (
            last == 0 or time.time() - last < self.max_poll_age
        )
        self.send_response(200 if healthy else 503)
        self.end_headers()
        self.wfile.write(b"ok" if healthy else b"stale")

    def log_message(self, *args: Any) -> None:
        return


def main() -> None:
    url = os.environ["QUEUE_URL"]
    start_http_server(int(os.getenv("METRICS_PORT", "9090")))
    server = HTTPServer(("0.0.0.0", int(os.getenv("HEALTH_PORT", "8080"))), Health)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    queue = SqsQueue(url)
    log.info(json.dumps({"msg": "worker started"}))
    while not stop.is_set():
        try:
            handle_batch(queue)
        except Exception as exc:  # noqa: BLE001 - keep polling on transient AWS errors
            log.error(json.dumps({"msg": "poll failed", "error": str(exc)}))
            stop.wait(5)
    log.info(json.dumps({"msg": "worker stopped"}))


if __name__ == "__main__":
    main()
