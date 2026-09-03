import json
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from fastapi import HTTPException

from backend.config.settings import get_settings


def _decode_error(error: HTTPError) -> str:
    try:
        payload = json.loads(error.read().decode("utf-8"))
    except Exception:
        return str(error)

    if isinstance(payload, dict):
        return payload.get("message") or payload.get("error") or str(payload)
    return str(payload)


def call_supabase_rpc(
    function_name: str,
    payload: dict[str, Any] | None = None,
    *,
    user_jwt: str | None = None,
    service_role: bool = False,
) -> Any:
    settings = get_settings()
    if not settings.supabase_configured:
        raise HTTPException(status_code=503, detail="Supabase ainda não configurado no .env local.")

    api_key = settings.supabase_service_role_key if service_role else settings.supabase_anon_key
    if service_role and not settings.supabase_service_role_key:
        raise HTTPException(status_code=503, detail="SUPABASE_SERVICE_ROLE_KEY não configurada para webhooks.")

    token = api_key if service_role else user_jwt
    if not token:
        raise HTTPException(status_code=401, detail="Sessão obrigatória para operação de pagamento.")

    url = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/{function_name}"
    body = json.dumps(payload or {}).encode("utf-8")
    request = Request(
        url,
        data=body,
        method="POST",
        headers={
            "apikey": api_key,
            "authorization": f"Bearer {token}",
            "content-type": "application/json",
            "accept": "application/json",
        },
    )

    try:
        with urlopen(request, timeout=20) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw else None
    except HTTPError as error:
        raise HTTPException(status_code=error.code, detail=_decode_error(error)) from error
    except URLError as error:
        raise HTTPException(status_code=503, detail=f"Supabase indisponível: {error.reason}") from error
