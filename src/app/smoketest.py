import json
import os
import sys
import time
from typing import Any

import httpx

from app.main import netcheck_payload


def fail(message: str, details: Any | None = None) -> None:
    print("\n========== SMOKETEST FAIL ==========")
    print(message)
    if details is not None:
        print(json.dumps(details, indent=2, sort_keys=True))
    print("====================================")
    sys.exit(1)


def assert_private_dns() -> dict[str, Any]:
    payload = netcheck_payload()
    if not payload["ok"]:
        fail("One or more dependency FQDNs did not resolve to RFC1918 private addresses.", payload)
    return payload


def get_with_retry(client: httpx.Client, url: str, attempts: int = 12) -> httpx.Response:
    delay = 5
    last_error: Exception | None = None
    for _ in range(attempts):
        try:
            response = client.get(url)
            if response.status_code < 500:
                return response
        except Exception as exc:
            last_error = exc
        time.sleep(delay)
        delay = min(delay + 5, 30)
    if last_error:
        raise last_error
    raise RuntimeError(f"GET {url} did not become ready")


def main() -> int:
    backend_url = os.getenv("BACKEND_URL", "").rstrip("/")
    if not backend_url:
        fail("BACKEND_URL is not configured")
    local_dns = assert_private_dns()
    timeout = httpx.Timeout(60.0, connect=10.0)
    with httpx.Client(timeout=timeout, verify=True) as client:
        health = get_with_retry(client, f"{backend_url}/healthz")
        if health.status_code != 200:
            fail("Backend health check failed", {"status": health.status_code, "body": health.text})
        netcheck = client.get(f"{backend_url}/netcheck")
        if netcheck.status_code != 200:
            fail("Backend /netcheck failed", {"status": netcheck.status_code, "body": netcheck.text})
        backend_dns = netcheck.json()
        if not backend_dns.get("ok"):
            fail("Backend reported non-private DNS results", backend_dns)
        prompt = os.getenv("SMOKETEST_PROMPT", "Reply with exactly: PRIVATE_AGENT_PASS")
        ask = client.post(f"{backend_url}/ask", json={"question": prompt})
        if ask.status_code != 200:
            fail("Backend /ask failed", {"status": ask.status_code, "body": ask.text})
        reply = ask.json().get("reply", "")
        if not reply.strip():
            fail("Agent reply was empty", ask.json())
    print("\n========== SMOKETEST PASS ==========")
    print("All dependency FQDNs resolved to RFC1918 private addresses.")
    print("The internal Container Apps backend was reachable only from inside the VNet.")
    print("The Foundry Agent Service round trip succeeded.")
    print(json.dumps({"localDns": local_dns, "backendDns": backend_dns, "agentReply": reply}, indent=2, sort_keys=True))
    print("====================================")
    return 0


if __name__ == "__main__":
    sys.exit(main())
