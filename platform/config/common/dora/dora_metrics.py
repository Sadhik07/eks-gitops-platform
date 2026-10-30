#!/usr/bin/env python3
"""DORA metrics from GitHub, as a Prometheus exporter or a one-off report.

Data sources (all written by this repo's own workflows):
  * Deployments: GitHub Deployments in the target environment, created by
    .github/workflows/record-deployment.yaml whenever a change to
    deploy/overlays/prod/** merges. The payload carries the service name, the
    image tag, the commit timestamp of that image, and a rollback flag.
  * Incidents: issues labelled `incident` (plus `service:<name>`).

Definitions (medians, over a rolling window, default 30 days):
  * Deployment frequency  - production deployments per day (rollbacks excluded)
  * Lead time for changes - commit time of the image -> production deployment
  * Change failure rate   - share of deployments followed by a rollback, or by
                            an incident on the same service within 24h
  * Time to restore       - incident opened -> incident closed

Standard library only, so it runs on a stock python image with no installs.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import threading
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Iterable

API = os.getenv("GITHUB_API_URL", "https://api.github.com")
FAILURE_WINDOW = timedelta(hours=24)


@dataclass(frozen=True)
class Deployment:
    service: str
    created_at: datetime
    commit_at: datetime | None
    rollback: bool = False


@dataclass(frozen=True)
class Incident:
    service: str | None
    opened_at: datetime
    closed_at: datetime | None


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


# --------------------------------------------------------------------------
# Core calculation (pure, unit-tested)
# --------------------------------------------------------------------------
def compute(
    deployments: Iterable[Deployment],
    incidents: Iterable[Incident],
    now: datetime,
    window_days: int = 30,
) -> dict[str, float | int | None]:
    start = now - timedelta(days=window_days)
    in_window = sorted(
        (d for d in deployments if start <= d.created_at <= now),
        key=lambda d: d.created_at,
    )
    changes = [d for d in in_window if not d.rollback]
    incidents = [i for i in incidents if i.opened_at >= start]

    lead_times = [
        (d.created_at - d.commit_at).total_seconds()
        for d in changes
        if d.commit_at and d.commit_at <= d.created_at
    ]

    failed = 0
    for d in changes:
        nxt = next(
            (
                x
                for x in in_window
                if x.service == d.service and x.created_at > d.created_at
            ),
            None,
        )
        window_end = min(d.created_at + FAILURE_WINDOW, nxt.created_at if nxt else now)
        rolled_back = nxt is not None and nxt.rollback
        caused_incident = any(
            i.service == d.service and d.created_at <= i.opened_at < window_end
            for i in incidents
        )
        if rolled_back or caused_incident:
            failed += 1

    restore_times = [
        (i.closed_at - i.opened_at).total_seconds()
        for i in incidents
        if i.closed_at and i.closed_at >= i.opened_at
    ]

    return {
        "window_days": window_days,
        "deployments_total": len(changes),
        "rollbacks_total": len(in_window) - len(changes),
        "failed_deployments_total": failed,
        "incidents_total": len(incidents),
        "deployment_frequency_per_day": len(changes) / window_days,
        "lead_time_seconds_median": statistics.median(lead_times)
        if lead_times
        else None,
        "change_failure_rate": failed / len(changes) if changes else None,
        "time_to_restore_seconds_median": statistics.median(restore_times)
        if restore_times
        else None,
    }


def performance_band(metrics: dict[str, Any]) -> dict[str, str]:
    """Rough DORA bands (elite/high/medium/low) for the README-style report."""
    bands: dict[str, str] = {}
    freq = metrics["deployment_frequency_per_day"]
    bands["deployment_frequency"] = (
        "elite"
        if freq >= 1
        else "high"
        if freq >= 1 / 7
        else "medium"
        if freq >= 1 / 30
        else "low"
    )
    lt = metrics["lead_time_seconds_median"]
    if lt is not None:
        bands["lead_time"] = (
            "elite"
            if lt < 86400
            else "high"
            if lt < 7 * 86400
            else "medium"
            if lt < 30 * 86400
            else "low"
        )
    cfr = metrics["change_failure_rate"]
    if cfr is not None:
        bands["change_failure_rate"] = (
            "elite"
            if cfr <= 0.05
            else "high"
            if cfr <= 0.15
            else "medium"
            if cfr <= 0.30
            else "low"
        )
    ttr = metrics["time_to_restore_seconds_median"]
    if ttr is not None:
        bands["time_to_restore"] = (
            "elite"
            if ttr < 3600
            else "high"
            if ttr < 86400
            else "medium"
            if ttr < 7 * 86400
            else "low"
        )
    return bands


# --------------------------------------------------------------------------
# GitHub client
# --------------------------------------------------------------------------
class GitHub:
    def __init__(self, repo: str, token: str | None) -> None:
        self.repo = repo
        self.token = token

    def _get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        url = f"{API}/repos/{self.repo}{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(
            url, headers={"Accept": "application/vnd.github+json"}
        )
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 - fixed https host
            return json.load(resp)

    def _paged(
        self, path: str, params: dict[str, Any], max_pages: int = 10
    ) -> list[Any]:
        items: list[Any] = []
        for page in range(1, max_pages + 1):
            batch = self._get(path, {**params, "per_page": 100, "page": page})
            items.extend(batch)
            if len(batch) < 100:
                break
        return items

    def deployments(self, environment: str, since: datetime) -> list[Deployment]:
        out: list[Deployment] = []
        for d in self._paged("/deployments", {"environment": environment}):
            created = parse_ts(d["created_at"])
            if created is None or created < since:
                continue
            statuses = self._get(f"/deployments/{d['id']}/statuses", {"per_page": 1})
            if not statuses or statuses[0].get("state") != "success":
                continue
            payload = d.get("payload") or {}
            if isinstance(payload, str):
                payload = json.loads(payload or "{}")
            out.append(
                Deployment(
                    service=payload.get("service", "unknown"),
                    created_at=created,
                    commit_at=parse_ts(payload.get("commit_timestamp")),
                    rollback=bool(payload.get("rollback", False)),
                )
            )
        return out

    def incidents(self, since: datetime) -> list[Incident]:
        params = {"labels": "incident", "state": "all", "since": since.isoformat()}
        out: list[Incident] = []
        for issue in self._paged("/issues", params):
            if "pull_request" in issue:
                continue
            labels = [lbl["name"] for lbl in issue.get("labels", [])]
            service = next(
                (lbl.split(":", 1)[1] for lbl in labels if lbl.startswith("service:")),
                None,
            )
            out.append(
                Incident(
                    service=service,
                    opened_at=parse_ts(issue["created_at"]),
                    closed_at=parse_ts(issue.get("closed_at")),
                )
            )
        return out


# --------------------------------------------------------------------------
# Output formats
# --------------------------------------------------------------------------
GAUGES = {
    "deployment_frequency_per_day": "Production deployments per day over the window",
    "lead_time_seconds_median": "Median commit-to-production time",
    "change_failure_rate": "Share of deployments that caused a rollback or incident",
    "time_to_restore_seconds_median": "Median incident duration",
    "deployments_total": "Production deployments in the window",
    "failed_deployments_total": "Failed production deployments in the window",
    "incidents_total": "Incidents opened in the window",
}


def to_prometheus(metrics: dict[str, Any], environment: str) -> str:
    lines = []
    for key, help_text in GAUGES.items():
        value = metrics.get(key)
        if value is None:
            continue
        name = f"dora_{key}"
        lines += [f"# HELP {name} {help_text}", f"# TYPE {name} gauge"]
        lines.append(f'{name}{{environment="{environment}"}} {float(value):g}')
    return "\n".join(lines) + "\n"


def human(seconds: float | None) -> str:
    if seconds is None:
        return "n/a"
    if seconds < 3600:
        return f"{seconds / 60:.0f} min"
    if seconds < 86400:
        return f"{seconds / 3600:.1f} h"
    return f"{seconds / 86400:.1f} days"


def to_markdown(metrics: dict[str, Any], environment: str) -> str:
    bands = performance_band(metrics)
    cfr = metrics["change_failure_rate"]
    rows = [
        (
            "Deployment frequency",
            f"{metrics['deployment_frequency_per_day']:.2f} / day",
            bands.get("deployment_frequency", "n/a"),
        ),
        (
            "Lead time for changes (median)",
            human(metrics["lead_time_seconds_median"]),
            bands.get("lead_time", "n/a"),
        ),
        (
            "Change failure rate",
            "n/a" if cfr is None else f"{cfr:.0%}",
            bands.get("change_failure_rate", "n/a"),
        ),
        (
            "Time to restore (median)",
            human(metrics["time_to_restore_seconds_median"]),
            bands.get("time_to_restore", "n/a"),
        ),
    ]
    out = [
        f"## DORA metrics: {environment}, last {metrics['window_days']} days",
        "",
        "| Metric | Value | Band |",
        "|---|---|---|",
        *[f"| {a} | {b} | {c} |" for a, b, c in rows],
        "",
        f"{metrics['deployments_total']} deployments, {metrics['rollbacks_total']} rollbacks, "
        f"{metrics['incidents_total']} incidents.",
    ]
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# Entry points
# --------------------------------------------------------------------------
def load_fixtures(path: str) -> tuple[list[Deployment], list[Incident], datetime]:
    with open(path) as fh:
        data = json.load(fh)
    deps = [
        Deployment(
            d["service"],
            parse_ts(d["created_at"]),
            parse_ts(d.get("commit_at")),
            d.get("rollback", False),
        )
        for d in data.get("deployments", [])
    ]
    incs = [
        Incident(
            i.get("service"), parse_ts(i["opened_at"]), parse_ts(i.get("closed_at"))
        )
        for i in data.get("incidents", [])
    ]
    return deps, incs, parse_ts(data["now"])


def read_token() -> str | None:
    """GITHUB_TOKEN_FILE (mounted secret) wins over GITHUB_TOKEN (CI)."""
    path = os.getenv("GITHUB_TOKEN_FILE")
    if path and os.path.exists(path):
        with open(path) as fh:
            return fh.read().strip()
    return os.getenv("GITHUB_TOKEN")


def collect(args: argparse.Namespace) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    if args.fixtures:
        deps, incs, now = load_fixtures(args.fixtures)
    else:
        repo = os.environ["GITHUB_REPOSITORY"]
        gh = GitHub(repo, read_token())
        since = now - timedelta(days=args.window_days + 1)
        deps, incs = gh.deployments(args.environment, since), gh.incidents(since)
    return compute(deps, incs, now, args.window_days)


def serve(args: argparse.Namespace) -> None:
    state = {"body": "# no data yet\n"}

    def refresh() -> None:
        while True:
            try:
                metrics = collect(args)
                body = to_prometheus(metrics, args.environment)
                body += f"dora_last_refresh_timestamp_seconds {time.time():.0f}\n"
                state["body"] = body
            except Exception as exc:  # noqa: BLE001 - keep serving the last good data
                print(
                    json.dumps({"msg": "refresh failed", "error": str(exc)}),
                    file=sys.stderr,
                )
            time.sleep(args.refresh_seconds)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            if self.path != "/metrics":
                self.send_response(404)
                self.end_headers()
                return
            body = state["body"].encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a: Any) -> None:
            return

    threading.Thread(target=refresh, daemon=True).start()
    HTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--environment", default=os.getenv("DORA_ENVIRONMENT", "prod"))
    p.add_argument(
        "--window-days", type=int, default=int(os.getenv("DORA_WINDOW_DAYS", "30"))
    )
    p.add_argument(
        "--format", choices=["json", "markdown", "prometheus"], default="markdown"
    )
    p.add_argument(
        "--fixtures",
        help="read deployments/incidents from a JSON file instead of GitHub",
    )
    p.add_argument("--serve", action="store_true", help="run as a Prometheus exporter")
    p.add_argument("--port", type=int, default=9100)
    p.add_argument("--refresh-seconds", type=int, default=900)
    args = p.parse_args(argv)

    if args.serve:
        serve(args)
        return 0
    metrics = collect(args)
    if args.format == "json":
        print(json.dumps(metrics, indent=2))
    elif args.format == "prometheus":
        print(to_prometheus(metrics, args.environment), end="")
    else:
        print(to_markdown(metrics, args.environment), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
