import ipaddress
import os
import socket
from typing import Any

from azure.ai.agents import AgentsClient
from azure.ai.agents.models import MessageRole
from azure.identity import DefaultAzureCredential
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

RFC1918_NETWORKS = tuple(ipaddress.ip_network(cidr) for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
FQDN_ENV = {"foundry": "FOUNDRY_FQDN", "cosmos": "COSMOS_FQDN", "search": "SEARCH_FQDN", "storage": "STORAGE_FQDN"}

app = FastAPI(title="Azure private Foundry Agent PoC", version="0.1.0")


class AskRequest(BaseModel):
    question: str = Field(..., min_length=1, max_length=4000)


class AskResponse(BaseModel):
    reply: str


def is_rfc1918(address: str) -> bool:
    ip = ipaddress.ip_address(address)
    return any(ip in network for network in RFC1918_NETWORKS)


def resolve_fqdn(fqdn: str) -> list[str]:
    answers = socket.getaddrinfo(fqdn, 443, proto=socket.IPPROTO_TCP)
    ips = sorted({answer[4][0] for answer in answers})
    if not ips:
        raise RuntimeError(f"No A records resolved for {fqdn}")
    return ips


def netcheck_payload() -> dict[str, Any]:
    checks: dict[str, Any] = {}
    failures: list[str] = []
    for name, env_name in FQDN_ENV.items():
        fqdn = os.getenv(env_name)
        if not fqdn:
            failures.append(f"{env_name} is not set")
            checks[name] = {"fqdn": None, "ips": [], "allPrivate": False}
            continue
        try:
            ips = resolve_fqdn(fqdn)
            all_private = all(is_rfc1918(ip) for ip in ips)
            if not all_private:
                failures.append(f"{fqdn} resolved to at least one non-RFC1918 address: {ips}")
            checks[name] = {"fqdn": fqdn, "ips": ips, "allPrivate": all_private}
        except Exception as exc:
            failures.append(f"{fqdn} resolution failed: {exc}")
            checks[name] = {"fqdn": fqdn, "ips": [], "allPrivate": False, "error": str(exc)}
    return {"ok": not failures, "checks": checks, "failures": failures}


def text_from_message(message: Any) -> str | None:
    for item in getattr(message, "content", []) or []:
        if getattr(item, "type", None) == "text":
            text = getattr(getattr(item, "text", None), "value", None)
            if text:
                return text
    return None


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/netcheck")
def netcheck() -> dict[str, Any]:
    return netcheck_payload()


@app.post("/ask", response_model=AskResponse)
def ask(request: AskRequest) -> AskResponse:
    endpoint = os.getenv("PROJECT_ENDPOINT")
    model = os.getenv("MODEL_DEPLOYMENT_NAME", "gpt-4o-mini")
    if not endpoint:
        raise HTTPException(status_code=500, detail="PROJECT_ENDPOINT is not configured")

    credential = DefaultAzureCredential()
    client = AgentsClient(endpoint=endpoint, credential=credential)
    agent = None
    try:
        agent = client.create_agent(model=model, name="private-network-poc-agent", instructions="Answer briefly. This request is part of a private networking smoke test.")
        thread = client.threads.create()
        client.messages.create(thread_id=thread.id, role=MessageRole.USER, content=request.question)
        run = client.runs.create_and_process(thread_id=thread.id, agent_id=agent.id)
        if getattr(run, "status", None) not in ("completed", "Completed", None):
            raise RuntimeError(f"Agent run ended with status {run.status}")
        for message in client.messages.list(thread_id=thread.id):
            role = str(getattr(message, "role", "")).lower()
            if "agent" in role or "assistant" in role:
                text = text_from_message(message)
                if text:
                    return AskResponse(reply=text)
        raise RuntimeError("Agent completed but returned no assistant message")
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    finally:
        if agent is not None:
            try:
                client.delete_agent(agent.id)
            except Exception:
                pass
