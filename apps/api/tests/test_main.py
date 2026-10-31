from fastapi.testclient import TestClient

from app.main import create_app


def client(monkeypatch, fault_rate: str = "0") -> TestClient:
    monkeypatch.setenv("FAULT_RATE", fault_rate)
    monkeypatch.delenv("QUEUE_URL", raising=False)
    return TestClient(create_app())


def test_health_and_ready(monkeypatch):
    c = client(monkeypatch)
    assert c.get("/healthz").json() == {"status": "ok"}
    assert c.get("/readyz").status_code == 200


def test_create_order_is_queued(monkeypatch):
    app = create_app()
    c = TestClient(app)
    r = c.post("/api/orders", json={"sku": "ABC-1", "quantity": 2})
    assert r.status_code == 202
    assert app.state.queue.memory[0]["sku"] == "ABC-1"


def test_invalid_order_rejected(monkeypatch):
    c = client(monkeypatch)
    assert c.post("/api/orders", json={"sku": "", "quantity": 0}).status_code == 422


def test_fault_injection_returns_500(monkeypatch):
    c = client(monkeypatch, fault_rate="1")
    assert c.get("/api/version").status_code == 500
    # probes are never faulted, so a bad canary fails analysis, not liveness
    assert c.get("/healthz").status_code == 200


def test_metrics_exposed(monkeypatch):
    c = client(monkeypatch)
    c.get("/api/version")
    body = c.get("/metrics").text
    assert "http_requests_total" in body
    assert "http_request_duration_seconds_bucket" in body


def test_unknown_queue_backend_is_rejected(monkeypatch):
    import pytest

    monkeypatch.setenv("QUEUE_BACKEND", "kafka")
    with pytest.raises(ValueError):
        create_app()


def test_service_bus_backend_sends_json(monkeypatch):
    """The Azure path builds a ServiceBusMessage and sends it through the queue sender."""
    import sys
    import types

    sent = []

    class FakeSender:
        def send_messages(self, message):
            sent.append(message)

    class FakeClient:
        def __init__(self, namespace, credential, transport_type):
            assert namespace == "sb-test.servicebus.windows.net"

        def get_queue_sender(self, name):
            assert name == "orders"
            return FakeSender()

    sb = types.ModuleType("azure.servicebus")
    sb.ServiceBusClient = FakeClient
    sb.TransportType = types.SimpleNamespace(AmqpOverWebsocket="ws")
    sb.ServiceBusMessage = lambda body, content_type: {
        "body": body,
        "type": content_type,
    }
    ident = types.ModuleType("azure.identity")
    ident.DefaultAzureCredential = lambda: object()
    monkeypatch.setitem(sys.modules, "azure.servicebus", sb)
    monkeypatch.setitem(sys.modules, "azure.identity", ident)
    monkeypatch.setenv("QUEUE_BACKEND", "servicebus")
    monkeypatch.setenv("SERVICEBUS_NAMESPACE", "sb-test.servicebus.windows.net")

    c = TestClient(create_app())
    assert c.post("/api/orders", json={"sku": "AZ-1", "quantity": 1}).status_code == 202
    assert (
        sent
        and '"sku": "AZ-1"' in sent[0]["body"]
        and sent[0]["type"] == "application/json"
    )
