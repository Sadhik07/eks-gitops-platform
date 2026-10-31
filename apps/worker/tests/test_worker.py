import json

import worker


class FakeQueue:
    def __init__(self, messages):
        self.messages = messages
        self.deleted = []

    def receive(self):
        batch, self.messages = self.messages, []
        return batch

    def delete(self, receipt_handle):
        self.deleted.append(receipt_handle)

    def finish_batch(self):
        pass


def msg(body, handle, sent_ms=1_000_000):
    return {
        "Body": json.dumps(body),
        "ReceiptHandle": handle,
        "Attributes": {"SentTimestamp": str(sent_ms)},
    }


def test_good_messages_are_deleted(monkeypatch):
    monkeypatch.setenv("PROCESS_DELAY_SECONDS", "0")
    q = FakeQueue(
        [msg({"id": "1", "quantity": 1}, "h1"), msg({"id": "2", "quantity": 3}, "h2")]
    )
    assert worker.handle_batch(q, now=1_010.0) == (2, 0)
    assert q.deleted == ["h1", "h2"]


def test_bad_message_left_for_redelivery(monkeypatch):
    monkeypatch.setenv("PROCESS_DELAY_SECONDS", "0")
    q = FakeQueue(
        [msg({"id": "1", "quantity": 0}, "bad"), msg({"id": "2", "quantity": 1}, "ok")]
    )
    assert worker.handle_batch(q, now=1_010.0) == (1, 1)
    assert q.deleted == ["ok"]


def test_message_age_metric(monkeypatch):
    monkeypatch.setenv("PROCESS_DELAY_SECONDS", "0")
    q = FakeQueue([msg({"id": "1", "quantity": 1}, "h", sent_ms=1_000_000)])
    worker.handle_batch(q, now=1_030.0)
    assert worker.MESSAGE_AGE._value.get() == 30.0


class FakeSbMessage:
    def __init__(self, body, token, enqueued):
        self.body, self.lock_token, self.enqueued_time_utc = body, token, enqueued

    def __str__(self):
        return self.body


class FakeReceiver:
    def __init__(self, messages):
        self.messages = messages
        self.completed, self.abandoned = [], []

    def receive_messages(self, max_message_count, max_wait_time):
        batch, self.messages = self.messages, []
        return batch

    def complete_message(self, msg):
        self.completed.append(msg.lock_token)

    def abandon_message(self, msg):
        self.abandoned.append(msg.lock_token)


def test_service_bus_completes_good_and_abandons_failed(monkeypatch):
    from datetime import datetime, timezone

    monkeypatch.setenv("PROCESS_DELAY_SECONDS", "0")
    sent = datetime.fromtimestamp(1_000, tz=timezone.utc)
    receiver = FakeReceiver(
        [
            FakeSbMessage(json.dumps({"id": "1", "quantity": 2}), "tok-ok", sent),
            FakeSbMessage(json.dumps({"id": "2", "quantity": 0}), "tok-bad", sent),
        ]
    )
    q = worker.ServiceBusQueue("ns.servicebus.windows.net", "orders", receiver=receiver)
    assert worker.handle_batch(q, now=1_020.0) == (1, 1)
    assert receiver.completed == ["tok-ok"]
    assert receiver.abandoned == [
        "tok-bad"
    ]  # redelivered now, dead-lettered after 5 tries
    assert worker.MESSAGE_AGE._value.get() == 20.0


def test_make_queue_rejects_unknown_backend(monkeypatch):
    import pytest

    monkeypatch.setenv("QUEUE_BACKEND", "kafka")
    with pytest.raises(ValueError):
        worker.make_queue()
