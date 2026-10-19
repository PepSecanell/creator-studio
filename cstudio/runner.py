"""Run `claude -p` headless. Sorts every run into ok, auth_expired, usage_limit, transient or failure and retries the
temporary kind. No API keys: it uses whatever login the Claude Code CLI already has."""
from __future__ import annotations

import json
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

OK, AUTH, LIMIT, TRANSIENT, FAILURE = "ok", "auth_expired", "usage_limit", "transient", "failure"
BACKOFF_S = (30, 90, 240)

_LIMIT = re.compile(r"hit your .{0,25}limit|usage limit|session limit|weekly limit|limit reached|out of (extra )?usage|"
                    r"credit balance is too low", re.I)
_AUTH = re.compile(r"failed to authenticate|oauth (session|token)[^.\n]{0,40}(expired|revoked|invalid)|not logged in|"
                   r"please run /login|run /login|invalid api key|authentication_error|api error: 401|invalid bearer token", re.I)
_TRANSIENT = re.compile(r"api error: 5\d\d|internal server error|overloaded|service unavailable|bad gateway|gateway time-?out|"
                        r"econnreset|etimedout|enotfound|econnrefused|socket hang up|fetch failed|network error|"
                        r"connection (error|reset|closed|refused)|unable to connect|timed out|temporarily unavailable|"
                        r"rate_limit_error|api error: 429", re.I)

MESSAGES = {
    AUTH: "Claude Code is not logged in. Run `claude` once and sign in, then try again.",
    LIMIT: "Your Claude usage limit is reached. Try again after it resets.",
    TRANSIENT: "Claude was not reachable after several tries. Check your connection and try again.",
}


@dataclass
class Verdict:
    kind: str
    detail: str = ""


@dataclass
class Result:
    kind: str = FAILURE
    text: str = ""
    detail: str = ""
    session_id: str = ""
    cost_usd: float = 0.0
    attempts: int = 0
    notes: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.kind == OK

    def explain(self) -> str:
        return MESSAGES.get(self.kind) or self.detail or "Claude failed."


def classify(text: str = "", *, exit_code: int = 0, is_error: bool | None = None, timed_out: bool = False) -> Verdict:
    """Classify one run from its error text. A successful run is never searched for error words."""
    if is_error is None:
        is_error = exit_code != 0
    if not is_error and exit_code == 0 and not timed_out:
        return Verdict(OK)
    head = (text or "").strip()[:1500]
    if _LIMIT.search(head):
        return Verdict(LIMIT, head[:200])
    if _AUTH.search(head):
        return Verdict(AUTH, head[:200])
    if timed_out:
        return Verdict(FAILURE, "stopped at the time limit")
    if _TRANSIENT.search(head):
        return Verdict(TRANSIENT, head[:200])
    return Verdict(FAILURE, head[:300] or f"claude exited with code {exit_code}")


def model_for(brand: dict | None, role: str) -> str:
    """role is "creative" (design and taste calls) or "mechanical" (everything else)."""
    models = (brand or {}).get("models") or {}
    return models.get(role) or {"creative": "opus", "mechanical": "sonnet"}[role]


def _parse(stdout: str) -> dict:
    try:
        d = json.loads(stdout)
    except json.JSONDecodeError:
        return {}
    return d if isinstance(d, dict) else {}


def run(prompt: str, *, role: str = "mechanical", brand: dict | None = None, cwd: Path | str | None = None,
        timeout_s: float = 3600, claude_bin: str = "claude", allowed_tools: str | None = None,
        max_retries: int = 3, backoff=BACKOFF_S, sleep=time.sleep, model: str | None = None) -> Result:
    """Run one prompt. Never raises for a failed run: look at .kind."""
    res = Result()
    cmd = [claude_bin, "-p", "--output-format", "json", "--model", model or model_for(brand, role)]
    if allowed_tools:
        cmd += ["--allowedTools", allowed_tools]
    retries = 0
    while True:
        res.attempts += 1
        timed_out = False
        try:
            r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, cwd=cwd, timeout=timeout_s)
            code, out, err = r.returncode, r.stdout, r.stderr
        except subprocess.TimeoutExpired:
            code, out, err, timed_out = 1, "", "", True
        except FileNotFoundError:
            res.kind, res.detail = FAILURE, "The claude command is not installed. See https://claude.com/claude-code"
            return res
        data = _parse(out)
        res.text = str(data.get("result", out if code == 0 else ""))
        res.session_id = data.get("session_id", res.session_id)
        res.cost_usd += float(data.get("total_cost_usd") or 0)
        if data:
            is_err = bool(data.get("is_error")) or code != 0
            v = classify(res.text if is_err else "", exit_code=code, is_error=is_err, timed_out=timed_out)
        else:
            v = classify(err or out, exit_code=code, timed_out=timed_out)
        res.kind, res.detail = v.kind, v.detail
        if v.kind == TRANSIENT and retries < max_retries:
            wait = backoff[min(retries, len(backoff) - 1)]
            retries += 1
            res.notes.append(f"temporary error, retry {retries}/{max_retries} after {wait}s")
            sleep(wait)
            continue
        return res


def extract_json(text: str):
    """Pull the first JSON object out of a model reply (it may sit inside a code fence)."""
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    chunk = m.group(1) if m else text[text.find("{"):text.rfind("}") + 1] if "{" in text else ""
    try:
        return json.loads(chunk)
    except json.JSONDecodeError:
        return None
