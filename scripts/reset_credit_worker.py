#!/usr/bin/env python3
"""Opt-in expiry protection for earned Codex reset credits.

The normal usage collector remains read-only. This separate worker performs
account-changing RPCs only under a persisted, account-bound user policy.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import signal
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable

from token_monitor import AppServerClient, LocalNotifier, UsageStore

POLICY_KEY = "reset_credits.auto_policy"
STATUS_KEY = "reset_credits.auto_worker_status"
POLL_SECONDS = 60


def policy(store: UsageStore) -> dict[str, Any]:
    try:
        value = json.loads(store.get_state(POLICY_KEY, "{}") or "{}")
    except (TypeError, ValueError):
        return {"enabled": False}
    if not isinstance(value, dict):
        return {"enabled": False}
    valid = (value.get("enabled") is True and isinstance(value.get("accountId"), str)
             and bool(value["accountId"].strip()) and type(value.get("leadMinutes")) is int
             and 1 <= value["leadMinutes"] <= 1440)
    return value if valid else {"enabled": False}


def read_status(store: UsageStore, limit: int = 20) -> dict[str, Any]:
    """Local metadata only; safe to call alongside the singleton daemon."""
    config = policy(store)
    try:
        worker = json.loads(store.get_state(STATUS_KEY, "{}") or "{}")
        if not isinstance(worker, dict):
            worker = {}
    except (TypeError, ValueError):
        worker = {}
    attempts = []
    with store._connect() as connection:
        rows = connection.execute("SELECT value FROM state WHERE key GLOB 'reset_credits.auto_attempt.*'").fetchall()
    allowed = ("creditId", "accountId", "expiresAt", "idempotencyKey", "attempts", "lastAttemptAt", "firstAttemptAt", "scheduledAt", "nextAttemptAt", "outcome", "errorKind")
    for row in rows:
        try:
            item = json.loads(row["value"])
            if isinstance(item, dict) and item.get("accountId") == config.get("accountId"):
                attempts.append({key: item[key] for key in allowed if key in item})
        except (TypeError, ValueError):
            pass
    attempts.sort(key=lambda item: item.get("lastAttemptAt", 0), reverse=True)
    plans = worker.get("plans", []) if config.get("enabled") else []
    scheduled = [item["scheduledAt"] for item in plans
                 if isinstance(item, dict) and type(item.get("scheduledAt")) is int]
    return {"policy": config, "worker": worker, "lastCheckAt": worker.get("checkedAt"),
            "nextScheduledAt": min(scheduled) if scheduled else None,
            "attempts": attempts[:max(1, min(50, limit))]}


@contextmanager
def worker_lock(store: UsageStore):
    path = store.data_dir / "reset-credit-worker.lock"
    with path.open("a") as handle:
        path.chmod(0o600)
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


class ResetCreditWorker:
    def __init__(self, store: UsageStore, client: Any = None,
                 now: Callable[[], int] = lambda: int(time.time()), notifier: Any = None):
        self.store = store
        self.client = client
        self.now = now
        self.notifier = notifier or LocalNotifier(store)
        self.owns_client = client is None
        self._tick_flags: dict[str, Any] = {}

    def close(self) -> None:
        if self.client is not None and self.owns_client:
            self.client.close()
            self.client = None

    def _request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        if self.client is None:
            self.client = AppServerClient(self.store, lambda _: None)
            self.client.start()
        return self.client.request(method, params)

    def _status(self, **data: Any) -> dict[str, Any]:
        value = {"checkedAt": self.now(), **self._tick_flags, **data}
        if not data.get("dryRun"):
            self.store.set_state(STATUS_KEY, value)
        return value

    def _notify(self, title: str, body: str) -> None:
        try:
            self.notifier.send(title, body)
        except Exception:
            # Delivery failure cannot invalidate a confirmed server-side reset.
            pass

    @staticmethod
    def _ledger_key(account: str, credit: str) -> str:
        digest = hashlib.sha256((account + "\0" + credit).encode()).hexdigest()
        return "reset_credits.auto_attempt." + digest

    def _load_attempt(self, key: str) -> dict[str, Any]:
        raw = self.store.get_state(key)
        if not raw:
            return {}
        # A damaged ledger must fail closed rather than issue a fresh key for
        # an attempt whose server-side outcome could already be successful.
        result = json.loads(raw)
        if not isinstance(result, dict) or not isinstance(result.get("idempotencyKey"), str):
            raise ValueError("Invalid reset attempt ledger")
        uuid.UUID(result["idempotencyKey"])
        return result

    def _candidates(self, raw: dict[str, Any], now: int) -> list[dict[str, Any]]:
        info = raw.get("rateLimitResetCredits")
        if not isinstance(info, dict) or not isinstance(info.get("credits"), list):
            return []
        result = {}
        for credit in info["credits"]:
            if not isinstance(credit, dict):
                continue
            ident, expires = credit.get("id"), credit.get("expiresAt")
            if (isinstance(ident, str) and ident and credit.get("status") == "available"
                    and credit.get("resetType") == "codexRateLimits"
                    and type(expires) is int and expires > now):
                result[ident] = {"creditId": ident, "expiresAt": expires}
        return sorted(result.values(), key=lambda x: (x["expiresAt"], x["creditId"]))

    def _unfinished(self, account: str) -> list[tuple[str, dict[str, Any]]]:
        """Recover only attempts with persisted proof of the original window."""
        result = []
        with self.store._connect() as connection:
            rows = connection.execute("SELECT key,value FROM state WHERE key GLOB 'reset_credits.auto_attempt.*'").fetchall()
        for row in rows:
            try:
                value = json.loads(row["value"])
            except (TypeError, ValueError):
                continue
            if not isinstance(value, dict) or value.get("accountId") != account:
                continue
            if value.get("outcome") not in ("pending", "error", "outcomeUnconfirmed"):
                continue
            ident = value.get("creditId")
            if not isinstance(ident, str) or not ident or self._ledger_key(account, ident) != row["key"]:
                raise ValueError("Invalid reset attempt identity")
            value = self._load_attempt(row["key"])
            proof = (all(type(value.get(k)) is int for k in ("scheduledAt", "firstAttemptAt", "expiresAt", "attempts"))
                     and value["attempts"] >= 1
                     and value["scheduledAt"] <= value["firstAttemptAt"] < value["expiresAt"])
            result.append((row["key"], {**value, "windowProof": proof}))
        return result

    def _problem(self, state: str, title: str, body: str, dry_run: bool = False, **data: Any) -> dict[str, Any]:
        if not dry_run and read_status(self.store)["worker"].get("state") != state:
            self.store.add_event("auto_reset_" + state, body)
            self._notify(title, body)
        return self._status(state=state, dryRun=dry_run, **data)

    def tick(self, dry_run: bool = False) -> dict[str, Any]:
        self._tick_flags = {}
        config = policy(self.store)
        if not config.get("enabled"):
            return self._status(state="disabled", dryRun=dry_run)
        raw = self._request("account/rateLimits/read")
        if raw.get("accountId") != config["accountId"]:
            if not dry_run and read_status(self.store)["worker"].get("state") != "accountMismatch":
                self.store.add_event("auto_reset_account_mismatch", "当前登录账号与自动重置授权账号不一致，已暂停兑换")
                self._notify("Codex 自动重置已暂停", "当前登录账号与授权账号不一致，请切回原账号或重新配置。")
            return self._status(state="accountMismatch", dryRun=dry_run, accountMatches=False)
        now = self.now()
        self.store.save_rate_limits(raw)
        unfinished = self._unfinished(config["accountId"])
        replays = []
        unconfirmed = []
        for key, saved in unfinished:
            if (saved["outcome"] == "outcomeUnconfirmed" or not saved["windowProof"]
                    or now >= saved["expiresAt"]):
                unconfirmed.append(saved["creditId"])
                if not dry_run and saved["outcome"] != "outcomeUnconfirmed":
                    saved.pop("windowProof", None)
                    saved["outcome"] = "outcomeUnconfirmed"
                    self.store.set_state(key, saved)
                    self.store.add_event("auto_reset_outcome_unconfirmed", "兑换结果未能在授权临期窗口内确认，已停止重放", {"creditId": saved["creditId"]})
                continue
            replays.append({"creditId": saved["creditId"], "expiresAt": saved["expiresAt"],
                            "scheduledAt": max(saved["scheduledAt"], saved["expiresAt"] - config["leadMinutes"] * 60),
                            "replay": True})
        info = raw.get("rateLimitResetCredits")
        # An explicit zero count is authoritative even when the optional list
        # is omitted. A positive count without full details cannot authorize a
        # new operation, but does not block replay of a proven existing one.
        reported = info.get("credits") if isinstance(info, dict) else None
        count = info.get("availableCount") if isinstance(info, dict) else None
        details_available = isinstance(info, dict) and (
            (type(count) is int and count == 0 and reported in (None, [])) or (
                isinstance(reported, list)
                and all(isinstance(credit, dict) and isinstance(credit.get("id"), str)
                        and bool(credit["id"]) for credit in reported)
                and (count is None or type(count) is int and count ==
                     sum(credit.get("status") == "available" for credit in reported))))
        self._tick_flags = {"accountMatches": True, "creditDetailsAvailable": details_available}
        if not details_available and not replays:
            return self._problem("creditDetailsUnavailable", "Codex 自动重置卡片信息暂不可用",
                                 "服务端暂未返回完整重置卡明细，已暂停新兑换并会重试。",
                                 dry_run, unconfirmedCreditIds=unconfirmed)
        candidates = self._candidates(raw, now) if details_available else []
        plans_by_id = {item["creditId"]: {**item, "scheduledAt": item["expiresAt"] - config["leadMinutes"] * 60}
                       for item in candidates}
        # An unknown prior response may mean the card was already consumed.
        # Replay the exact persisted operation, including when it disappeared
        # from the fresh list and usage is now zero. Never allocate a new key.
        plans_by_id.update({item["creditId"]: item for item in replays})
        plans = sorted(plans_by_id.values(), key=lambda item: (not item.get("replay", False), item["expiresAt"], item["creditId"]))
        due = [item for item in plans if item["scheduledAt"] <= now]
        if dry_run:
            return self._status(state="dryRun", dryRun=True, plans=plans, due=due,
                                unconfirmedCreditIds=unconfirmed, accountMatches=True, creditDetailsAvailable=details_available)
        if not due:
            if unconfirmed:
                return self._problem("outcomeUnconfirmed", "Codex 重置卡兑换结果未确认",
                                     "重置卡已超过授权兑换窗口，先前兑换结果仍未确认；后台不会在过期后再次调用兑换。",
                                     unconfirmedCreditIds=unconfirmed, plans=plans)
            return self._status(state="waiting", plans=plans)
        rows = UsageStore.flatten_rate_limits(raw)
        can_reset = bool(rows and any(row.get("usedPercent", 0) > 0 for row in rows))
        nothing_to_reset = False
        for item in due:
            key = self._ledger_key(config["accountId"], item["creditId"])
            attempt = self._load_attempt(key)
            if attempt.get("outcome") in ("reset", "alreadyRedeemed", "outcomeUnconfirmed"):
                continue
            if item.get("replay") and attempt.get("outcome") not in ("pending", "error"):
                continue
            if not item.get("replay") and not can_reset:
                nothing_to_reset = True
                continue
            if attempt.get("nextAttemptAt", 0) > now:
                continue
            # Re-read the policy immediately before every account-changing call.
            # Disabling or changing accounts while a read is in flight takes effect.
            if policy(self.store) != config:
                return self._status(state="policyChanged")
            if not item["scheduledAt"] <= self.now() < item["expiresAt"]:
                continue
            attempt = {**attempt, "idempotencyKey": (attempt.get("idempotencyKey")
                           if attempt.get("outcome") in ("pending", "error") else None) or str(uuid.uuid4()),
                       "creditId": item["creditId"], "accountId": config["accountId"],
                       "expiresAt": item["expiresAt"], "scheduledAt": attempt.get("scheduledAt", item["scheduledAt"]),
                       "firstAttemptAt": attempt.get("firstAttemptAt", self.now()),
                       "attempts": attempt.get("attempts", 0) + 1, "lastAttemptAt": self.now(),
                       "outcome": "pending"}
            # Persist before sending; a crash or timeout must reuse this key.
            self.store.set_state(key, attempt)
            try:
                result = self._request("account/rateLimitResetCredit/consume", {
                    "creditId": item["creditId"], "idempotencyKey": attempt["idempotencyKey"]})
                outcome = result.get("outcome")
                if outcome not in ("reset", "alreadyRedeemed", "nothingToReset", "noCredit"):
                    raise ValueError("Unknown reset outcome")
            except Exception as exc:
                outcome = "error"
                attempt["errorKind"] = type(exc).__name__
                # Never persist server exception bodies, which may contain secrets.
                if attempt["attempts"] == 1:
                    self.store.add_event("auto_reset_failed", "临期重置卡兑换暂未确认，将以相同幂等键重试", item)
                    self._notify("Codex 自动重置暂未确认", "临期重置卡兑换未确认，后台将重试；详见自动重置状态。")
                self.close()
            attempt["outcome"] = outcome
            attempt["nextAttemptAt"] = self.now() + min(300, 60 * 2 ** min(attempt["attempts"] - 1, 3))
            self.store.set_state(key, attempt)
            if outcome in ("reset", "alreadyRedeemed"):
                self.store.add_event("auto_reset_succeeded", "已在重置卡到期前自动兑换并重置额度", {
                    **item, "outcome": outcome, "idempotencyKey": attempt["idempotencyKey"]})
                self._notify("Codex 重置卡已自动使用", "已在到期前使用一张重置卡，服务端确认额度已重置。")
                # A later read reconciles usage/card display. Its failure must not
                # erase the confirmed successful result or lead to another key.
                try:
                    self.store.save_rate_limits(self._request("account/rateLimits/read"))
                except Exception:
                    self.close()
            return self._status(state=outcome, creditId=item["creditId"], plans=plans)
        if unconfirmed:
            return self._problem("outcomeUnconfirmed", "Codex 重置卡兑换结果未确认",
                                 "先前兑换结果未能在授权临期窗口内确认；不会在窗口外再次兑换。",
                                 unconfirmedCreditIds=unconfirmed, plans=plans)
        return self._status(state="nothingToReset" if nothing_to_reset else "waitingRetry", plans=plans)

    def safe_tick(self, dry_run: bool = False) -> dict[str, Any]:
        try:
            return self.tick(dry_run)
        except Exception as exc:
            self.close()
            previous = self.store.get_state(STATUS_KEY, "") or ""
            kind = type(exc).__name__
            if not dry_run and '"state":"error"' not in previous:
                self.store.add_event("auto_reset_worker_error", "自动重置后台检查失败，稍后重试", {"errorKind": kind})
                self._notify("Codex 自动重置检查失败", "后台暂时无法核查重置卡，将自动重试；请检查登录和网络。")
            return self._status(state="error", errorKind=kind, dryRun=dry_run)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--once", action="store_true", help="Check once and redeem a due card when enabled")
    modes.add_argument("--dry-run", action="store_true", help="Read fresh cards and show plans, never redeem")
    modes.add_argument("--status", action="store_true", help="Read saved policy and worker status only")
    modes.add_argument("--configure", action="store_true", help="Enable for an explicitly authorized account")
    modes.add_argument("--disable", action="store_true", help="Disable automatic redemption")
    parser.add_argument("--account-id")
    parser.add_argument("--lead-minutes", type=int, default=30)
    parser.add_argument("--data-dir", type=Path)
    args = parser.parse_args()
    if args.configure and (not args.account_id or not args.account_id.strip() or not 1 <= args.lead_minutes <= 1440):
        parser.error("--configure requires --account-id and --lead-minutes between 1 and 1440")
    store = UsageStore(args.data_dir)
    if args.configure:
        value = {"enabled": True, "accountId": args.account_id, "leadMinutes": args.lead_minutes}
        store.set_state(POLICY_KEY, value)
        print(json.dumps({"policy": value}, ensure_ascii=False))
        return 0
    if args.disable:
        store.set_state(POLICY_KEY, {"enabled": False})
        print(json.dumps({"policy": {"enabled": False}}))
        return 0
    if args.status:
        print(json.dumps(read_status(store), ensure_ascii=False))
        return 0
    if args.dry_run:
        worker = ResetCreditWorker(store)
        try:
            result = worker.safe_tick(dry_run=True)
            print(json.dumps(result, ensure_ascii=False))
            return 1 if result["state"] == "error" else 0
        finally:
            worker.close()
    with worker_lock(store) as acquired:
        if not acquired:
            print(json.dumps({"state": "alreadyRunning"}))
            return 0
        worker = ResetCreditWorker(store)
        stopped = threading.Event()
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda *_: stopped.set())
        try:
            while not stopped.is_set():
                result = worker.safe_tick(args.dry_run)
                if args.once or args.dry_run:
                    print(json.dumps(result, ensure_ascii=False))
                    return 1 if result["state"] == "error" else 0
                stopped.wait(POLL_SECONDS)
        finally:
            worker.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
