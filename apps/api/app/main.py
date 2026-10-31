"""Orders API: the service the canary pipeline ships.

Exposes Prometheus metrics, optional OpenTelemetry traces, health probes,
and a FAULT_RATE knob used in game days to prove automated rollback works.
"""

from __future__ import annotations

import json
import logging
import os
import random
import threading
import time
import uuid
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field

SERVICE_NAME = os.getenv("SERVICE_NAME", "api")
VERSION = os.getenv("APP_VERSION", "dev")


class JsonFormatter(logging.Formatter):
    """Structured logs so Loki/CloudWatch can filter on fields."""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "service": SERVICE_NAME,
            "version": VERSION,
            "msg": record.getMessage(),
        }
        payload.update(getattr(record, "extra_fields", {}))
        return json.dumps(payload)


handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
log = logging.getLogger(SERVICE_NAME)
log.addHandler(handler)
log.setLevel(os.getenv("LOG_LEVEL", "INFO"))

REQUESTS = Counter(
    "http_requests_total", "HTTP requests", ["service", "route", "method", "code"]
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["service", "route", "method"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
ORDERS_ENQUEUED = Counter("orders_enqueued_total", "Orders accepted", ["service"])


class OrderIn(BaseModel):
    sku: str = Field(min_length=1, max_length=64)
    quantity: int = Field(gt=0, le=1000)


class Queue:
    """Where accepted orders go. Selected by QUEUE_BACKEND:

    * ``sqs``        - AWS SQS (QUEUE_URL); credentials from EKS Pod Identity
    * ``servicebus`` - Azure Service Bus (SERVICEBUS_NAMESPACE, QUEUE_NAME);
                       credentials from Entra Workload ID, AMQP over websockets
                       so only port 443 is needed
    * ``memory``     - in-process list for tests and quick local runs

    Without QUEUE_BACKEND, a set QUEUE_URL means SQS (backwards compatible).
    """

    def __init__(self) -> None:
        self.backend = os.getenv("QUEUE_BACKEND") or (
            "sqs" if os.getenv("QUEUE_URL") else "memory"
        )
        self.memory: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        if self.backend == "sqs":
            import boto3  # imported lazily so tests don't need cloud SDKs configured

            self.url = os.environ["QUEUE_URL"]
            self._sqs = boto3.client("sqs")
        elif self.backend == "servicebus":
            from azure.identity import DefaultAzureCredential
            from azure.servicebus import ServiceBusClient, TransportType

            self._sb = ServiceBusClient(
                os.environ["SERVICEBUS_NAMESPACE"],
                credential=DefaultAzureCredential(),
                transport_type=TransportType.AmqpOverWebsocket,
            )
            self._sender = self._sb.get_queue_sender(os.getenv("QUEUE_NAME", "orders"))
        elif self.backend != "memory":
            raise ValueError(f"unknown QUEUE_BACKEND '{self.backend}'")

    def send(self, message: dict[str, Any]) -> None:
        body = json.dumps(message)
        if self.backend == "sqs":
            self._sqs.send_message(QueueUrl=self.url, MessageBody=body)
        elif self.backend == "servicebus":
            from azure.servicebus import ServiceBusMessage

            with self._lock:  # a Service Bus sender is not thread-safe
                self._sender.send_messages(
                    ServiceBusMessage(body, content_type="application/json")
                )
        else:
            self.memory.append(message)


def fault_rate() -> float:
    try:
        return min(max(float(os.getenv("FAULT_RATE", "0")), 0.0), 1.0)
    except ValueError:
        return 0.0


def create_app() -> FastAPI:
    app = FastAPI(title="orders-api", version=VERSION)
    app.state.queue = Queue()
    app.state.ready = True
    _maybe_enable_tracing(app)

    @app.middleware("http")
    async def metrics_middleware(request: Request, call_next):
        start = time.perf_counter()
        status = 500
        try:
            if request.url.path.startswith("/api/") and random.random() < fault_rate():
                status = 500
                return Response(status_code=500, content="injected fault")
            response = await call_next(request)
            status = response.status_code
            return response
        finally:
            route = request.scope.get("route")
            path = getattr(route, "path", request.url.path)
            if path not in ("/metrics", "/healthz", "/readyz"):
                REQUESTS.labels(SERVICE_NAME, path, request.method, str(status)).inc()
                LATENCY.labels(SERVICE_NAME, path, request.method).observe(
                    time.perf_counter() - start
                )

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz")
    def readyz() -> dict[str, str]:
        if not app.state.ready:
            raise HTTPException(status_code=503, detail="not ready")
        return {"status": "ready"}

    @app.get("/metrics")
    def metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.get("/api/version")
    def version() -> dict[str, str]:
        return {"service": SERVICE_NAME, "version": VERSION}

    @app.post("/api/orders", status_code=202)
    def create_order(order: OrderIn) -> dict[str, str]:
        order_id = str(uuid.uuid4())
        app.state.queue.send({"id": order_id, **order.model_dump()})
        ORDERS_ENQUEUED.labels(SERVICE_NAME).inc()
        log.info("order accepted", extra={"extra_fields": {"order_id": order_id}})
        return {"id": order_id, "status": "queued"}

    return app


def _maybe_enable_tracing(app: FastAPI) -> None:
    """Enable OTel only when a collector endpoint is configured."""
    if not os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return
    try:
        from opentelemetry import trace
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import (
            OTLPSpanExporter,
        )
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
    except ImportError:
        log.warning("opentelemetry packages missing; tracing disabled")
        return
    provider = TracerProvider(
        resource=Resource.create(
            {"service.name": SERVICE_NAME, "service.version": VERSION}
        )
    )
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)
    FastAPIInstrumentor.instrument_app(app)


app = create_app()
