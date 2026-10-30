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
