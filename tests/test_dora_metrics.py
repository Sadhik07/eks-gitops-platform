import importlib.util
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# The script lives next to its Kubernetes manifests (it is mounted from a
# ConfigMap), so load it by path rather than as an installed package.
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "dora_metrics", ROOT / "platform/config/common/dora/dora_metrics.py"
)
dora = importlib.util.module_from_spec(spec)
sys.modules["dora_metrics"] = dora
spec.loader.exec_module(dora)

NOW = datetime(2026, 6, 30, 12, tzinfo=timezone.utc)


def dep(service, hours_ago, lead_hours=None, rollback=False):
    created = NOW - timedelta(hours=hours_ago)
    commit = created - timedelta(hours=lead_hours) if lead_hours is not None else None
    return dora.Deployment(service, created, commit, rollback)


def inc(service, hours_ago, duration_minutes=None):
    opened = NOW - timedelta(hours=hours_ago)
    closed = opened + timedelta(minutes=duration_minutes) if duration_minutes else None
    return dora.Incident(service, opened, closed)


def test_frequency_and_lead_time():
    deps = [dep("api", 48, 2), dep("api", 24, 4), dep("worker", 10, 6)]
    m = dora.compute(deps, [], NOW, window_days=30)
    assert m["deployments_total"] == 3
    assert m["deployment_frequency_per_day"] == 3 / 30
    assert m["lead_time_seconds_median"] == 4 * 3600


def test_rollback_marks_previous_deploy_failed_and_is_not_counted_as_change():
    deps = [dep("api", 30, 1), dep("api", 29, rollback=True)]
    m = dora.compute(deps, [], NOW)
    assert m["deployments_total"] == 1
    assert m["rollbacks_total"] == 1
    assert m["failed_deployments_total"] == 1
    assert m["change_failure_rate"] == 1.0


def test_incident_within_24h_on_same_service_counts_as_failure():
    deps = [dep("api", 100, 1), dep("worker", 100, 1)]
    incidents = [inc("api", 99, duration_minutes=45)]
    m = dora.compute(deps, incidents, NOW)
    assert m["failed_deployments_total"] == 1
    assert m["change_failure_rate"] == 0.5
    assert m["time_to_restore_seconds_median"] == 45 * 60


def test_incident_after_next_deploy_is_attributed_to_the_next_deploy():
    deps = [dep("api", 50, 1), dep("api", 40, 1)]
    incidents = [inc("api", 39, duration_minutes=10)]
    m = dora.compute(deps, incidents, NOW)
    assert m["failed_deployments_total"] == 1  # only the second deploy


def test_incident_older_than_24h_after_deploy_is_ignored():
    deps = [dep("api", 200, 1)]
    incidents = [inc("api", 100, duration_minutes=10)]
    assert dora.compute(deps, incidents, NOW)["failed_deployments_total"] == 0


def test_window_excludes_old_deployments_and_empty_data_is_safe():
    m = dora.compute([dep("api", 24 * 40, 1)], [], NOW, window_days=30)
    assert m["deployments_total"] == 0
    assert m["change_failure_rate"] is None
    assert m["lead_time_seconds_median"] is None


def test_bands():
    bands = dora.performance_band(
        {
            "deployment_frequency_per_day": 2.0,
            "lead_time_seconds_median": 3 * 3600,
            "change_failure_rate": 0.1,
            "time_to_restore_seconds_median": 30 * 60,
        }
    )
    assert bands == {
        "deployment_frequency": "elite",
        "lead_time": "elite",
        "change_failure_rate": "high",
        "time_to_restore": "elite",
    }


def test_prometheus_output_skips_missing_values():
    m = dora.compute([], [], NOW)
    text = dora.to_prometheus(m, "prod")
    assert 'dora_deployments_total{environment="prod"} 0' in text
    assert "dora_lead_time_seconds_median" not in text


def test_cli_with_fixtures(tmp_path, capsys):
    fixture = {
        "now": "2026-06-30T12:00:00Z",
        "deployments": [
            {
                "service": "api",
                "created_at": "2026-06-29T10:00:00Z",
                "commit_at": "2026-06-29T08:00:00Z",
            },
            {"service": "api", "created_at": "2026-06-29T11:00:00Z", "rollback": True},
        ],
        "incidents": [
            {
                "service": "api",
                "opened_at": "2026-06-29T10:20:00Z",
                "closed_at": "2026-06-29T11:05:00Z",
            }
        ],
    }
    path = tmp_path / "f.json"
    path.write_text(json.dumps(fixture))
    assert dora.main(["--fixtures", str(path), "--format", "json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["deployments_total"] == 1
    assert out["change_failure_rate"] == 1.0
    assert out["time_to_restore_seconds_median"] == 45 * 60
