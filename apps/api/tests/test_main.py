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
