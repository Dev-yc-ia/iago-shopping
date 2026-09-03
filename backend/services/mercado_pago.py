import json
import logging
import time
import traceback
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from fastapi import HTTPException

from backend.config.settings import ENV_FILE, get_settings


MERCADO_PAGO_API_BASE = "https://api.mercadopago.com"
logger = logging.getLogger("iago.shopping.payments")
EMPTY_LOG_VALUE = "VAZIO"


def _json_default(value: Any) -> str:
    if isinstance(value, datetime):
        return value.isoformat()
    return str(value)


def _as_log_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, default=_json_default)


def _mask_secret(value: Any) -> str:
    text = str(value or "").strip()
    if not text:
        return EMPTY_LOG_VALUE
    if len(text) <= 12:
        return f"{text[:3]}..."
    return f"{text[:12]}...{text[-6:]}"


def _mask_headers(headers: dict[str, Any]) -> dict[str, Any]:
    masked: dict[str, Any] = {}
    for key, value in headers.items():
        normalized = key.lower()
        if normalized == "authorization":
            scheme, _, token = str(value or "").partition(" ")
            masked[key] = f"{scheme} {_mask_secret(token)}" if token else _mask_secret(value)
        elif normalized in {"x-api-key", "api-key", "apikey"}:
            masked[key] = _mask_secret(value)
        else:
            masked[key] = value or EMPTY_LOG_VALUE
    return masked


def _mask_payload(value: Any) -> Any:
    if isinstance(value, dict):
        masked: dict[str, Any] = {}
        for key, item in value.items():
            if key.lower() in {
                "access_token",
                "authorization",
                "jwt",
                "service_role",
                "service_role_key",
                "public_key",
                "token",
            }:
                masked[key] = _mask_secret(item)
            else:
                masked[key] = _mask_payload(item)
        return masked
    if isinstance(value, list):
        return [_mask_payload(item) for item in value]
    return value if value not in {None, ""} else EMPTY_LOG_VALUE


def _present(value: Any) -> Any:
    return EMPTY_LOG_VALUE if value is None or value == "" or value == [] or value == {} else value


def _payment_log_fields(payload: dict[str, Any]) -> dict[str, Any]:
    transaction_data = (
        payload.get("point_of_interaction", {})
        .get("transaction_data", {})
        if isinstance(payload, dict)
        else {}
    )
    transaction_details = payload.get("transaction_details", {}) if isinstance(payload, dict) else {}
    return {
        "provider_status": _present(payload.get("status")),
        "payment_id": _present(payload.get("id")),
        "external_reference": _present(payload.get("external_reference")),
        "transaction_id": _present(transaction_details.get("transaction_id")),
        "qr_code": _present(transaction_data.get("qr_code")),
        "qr_code_base64": _present(transaction_data.get("qr_code_base64")),
        "ticket_url": _present(transaction_data.get("ticket_url")),
        "copia_cola": _present(transaction_data.get("qr_code")),
        "status_detail": _present(payload.get("status_detail")),
        "error": _present(payload.get("error")),
        "cause": _present(payload.get("cause")),
        "message": _present(payload.get("message")),
    }


def _exception_context(error: BaseException) -> dict[str, Any]:
    frames = traceback.extract_tb(error.__traceback__) if error.__traceback__ else []
    frame = frames[-1] if frames else None
    return {
        "exception_type": type(error).__name__,
        "exception_message": str(error) or EMPTY_LOG_VALUE,
        "file": frame.filename if frame else EMPTY_LOG_VALUE,
        "line": frame.lineno if frame else EMPTY_LOG_VALUE,
        "function": frame.name if frame else EMPTY_LOG_VALUE,
        "stacktrace": "".join(traceback.format_exception(type(error), error, error.__traceback__)),
    }


def _log_mercado_pago_request(
    *,
    url: str,
    path: str,
    method: str,
    provider_mode: str,
    payload: dict[str, Any] | None,
    headers: dict[str, Any],
    idempotency_key: str | None,
) -> None:
    logger.info(
        "Mercado Pago REQUEST\n%s",
        _as_log_json({
            "provider": provider_mode,
            "endpoint": url,
            "path": path,
            "method": method,
            "idempotency_key": _present(idempotency_key),
            "headers": _mask_headers(headers),
            "payload": _mask_payload(payload or {}),
        }),
    )


def _log_mercado_pago_response(
    *,
    url: str,
    path: str,
    method: str,
    provider_mode: str,
    payload: dict[str, Any] | None,
    request_headers: dict[str, Any],
    response_headers: dict[str, Any],
    response_payload: dict[str, Any],
    http_status: int,
    elapsed_ms: int,
    error: BaseException | None = None,
) -> None:
    log_payload = {
        "provider": provider_mode,
        "endpoint": url,
        "path": path,
        "method": method,
        "http_status": http_status,
        "elapsed_ms": elapsed_ms,
        "request_headers": _mask_headers(request_headers),
        "request_payload": _mask_payload(payload or {}),
        "response_headers": response_headers or EMPTY_LOG_VALUE,
        "response_json": response_payload or {},
        "fields": _payment_log_fields(response_payload or {}),
    }
    if http_status >= 400:
        log_payload["erro_tecnico"] = _present(response_payload.get("message") or response_payload.get("error"))
        log_payload["erro_negocio"] = _present(_mercado_pago_error_message("a operação", response_payload))
    if error:
        log_payload["python_exception"] = _exception_context(error)
    message = "Mercado Pago HTTP ERROR" if http_status >= 400 else "Mercado Pago RESPONSE"
    if error:
        logger.error(
            "%s\n%s",
            message,
            _as_log_json(log_payload),
            exc_info=(type(error), error, error.__traceback__),
        )
    else:
        logger.info("%s\n%s", message, _as_log_json(log_payload))


def _log_mercado_pago_exception(
    *,
    url: str,
    path: str,
    method: str,
    provider_mode: str,
    payload: dict[str, Any] | None,
    headers: dict[str, Any],
    elapsed_ms: int,
    error: BaseException,
) -> None:
    logger.exception(
        "Mercado Pago PYTHON EXCEPTION\n%s",
        _as_log_json({
            "provider": provider_mode,
            "endpoint": url,
            "path": path,
            "method": method,
            "elapsed_ms": elapsed_ms,
            "headers": _mask_headers(headers),
            "payload": _mask_payload(payload or {}),
            "python_exception": _exception_context(error),
        }),
    )


def _json_request(
    path: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    idempotency_key: str | None = None,
) -> tuple[dict[str, Any], dict[str, str], int, int]:
    settings = get_settings()
    if not settings.mercado_pago_access_token:
        raise HTTPException(
            status_code=503,
            detail=(
                "MERCADO_PAGO_ACCESS_TOKEN não carregado pelo backend. "
                f"Arquivo esperado: {ENV_FILE.resolve()}. Reinicie o backend após alterar o .env."
            ),
        )

    headers = {
        "Authorization": f"Bearer {settings.mercado_pago_access_token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    if idempotency_key:
        headers["X-Idempotency-Key"] = idempotency_key

    url = f"{MERCADO_PAGO_API_BASE}{path}"
    provider_mode = _sandbox_mode()
    body = json.dumps(payload or {}).encode("utf-8") if payload is not None else None
    request = Request(
        url,
        data=body,
        method=method,
        headers=headers,
    )

    started = time.perf_counter()
    _log_mercado_pago_request(
        url=url,
        path=path,
        method=method,
        provider_mode=provider_mode,
        payload=payload,
        headers=headers,
        idempotency_key=idempotency_key,
    )
    try:
        with urlopen(request, timeout=30) as response:
            elapsed_ms = int((time.perf_counter() - started) * 1000)
            raw = response.read().decode("utf-8")
            parsed = json.loads(raw) if raw else {}
            response_headers = dict(response.headers.items())
            _log_mercado_pago_response(
                url=url,
                path=path,
                method=method,
                provider_mode=provider_mode,
                payload=payload,
                request_headers=headers,
                response_headers=response_headers,
                response_payload=parsed,
                http_status=response.status,
                elapsed_ms=elapsed_ms,
            )
            return parsed, response_headers, response.status, elapsed_ms
    except HTTPError as error:
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        raw = error.read().decode("utf-8")
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"message": raw or str(error)}
        response_headers = dict(error.headers.items())
        _log_mercado_pago_response(
            url=url,
            path=path,
            method=method,
            provider_mode=provider_mode,
            payload=payload,
            request_headers=headers,
            response_headers=response_headers,
            response_payload=parsed,
            http_status=error.code,
            elapsed_ms=elapsed_ms,
            error=error,
        )
        return parsed, response_headers, error.code, elapsed_ms
    except URLError as error:
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        _log_mercado_pago_exception(
            url=url,
            path=path,
            method=method,
            provider_mode=provider_mode,
            payload=payload,
            headers=headers,
            elapsed_ms=elapsed_ms,
            error=error,
        )
        raise HTTPException(status_code=503, detail=f"Mercado Pago indisponível: {error.reason}") from error
    except Exception as error:
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        _log_mercado_pago_exception(
            url=url,
            path=path,
            method=method,
            provider_mode=provider_mode,
            payload=payload,
            headers=headers,
            elapsed_ms=elapsed_ms,
            error=error,
        )
        raise


def _mercado_pago_error_message(action: str, payload: dict[str, Any]) -> str:
    parts = [
        str(payload.get("message") or payload.get("error") or "").strip(),
        str(payload.get("status_detail") or "").strip(),
    ]
    causes = payload.get("cause")
    if isinstance(causes, list) and causes:
        cause = causes[0] or {}
        if isinstance(cause, dict):
            parts.extend([
                str(cause.get("code") or "").strip(),
                str(cause.get("description") or "").strip(),
            ])
    detail = " | ".join(part for part in parts if part)
    return f"Mercado Pago não aceitou {action}: {detail or 'resposta sem detalhe técnico.'}"


def _raise_for_mercado_pago_error(action: str, http_status: int, payload: dict[str, Any]) -> None:
    if http_status < 400:
        return
    status_code = 502 if http_status >= 500 else 400
    raise HTTPException(status_code=status_code, detail=_mercado_pago_error_message(action, payload))


def _parse_provider_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _provider_status_for_checkout(payload: dict[str, Any]) -> str | None:
    provider_status = payload.get("status")
    expiration = _parse_provider_datetime(payload.get("date_of_expiration"))
    if (
        str(provider_status or "").lower() in {"pending", "in_process", "action_required"}
        and expiration
        and expiration <= datetime.now(timezone.utc)
    ):
        return "expired"
    return provider_status


def _sandbox_mode() -> str:
    provider = get_settings().payment_provider.strip().lower()
    return "prod" if provider == "mercado_pago_prod" else "sandbox"


def build_idempotency_key(order_id: str, method: str) -> str:
    return f"iago:{_sandbox_mode()}:{order_id}:{method}:{uuid.uuid4()}"


def build_external_reference(order_id: str) -> str:
    return f"iago:{_sandbox_mode()}:{order_id}:{uuid.uuid4()}"


def payment_expiration_iso() -> str:
    minutes = max(1, min(get_settings().mercado_pago_payment_expiration_minutes, 1440))
    return (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat(timespec="seconds")


def create_payment_payload(
    order_context: dict[str, Any],
    method: str,
    card_payload: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], str, str]:
    settings = get_settings()
    order_id = str(order_context["pedido_id"])
    external_reference = build_external_reference(order_id)
    idempotency_key = build_idempotency_key(order_id, method)
    amount = float(order_context["total"])
    description = f"IAGO Shopping - Pedido #{order_context['numero']}"
    payer_email = order_context.get("cliente_email") or "test_user_000000@testuser.com"

    payload: dict[str, Any] = {
        "transaction_amount": amount,
        "description": description,
        "external_reference": external_reference,
        "payer": {"email": payer_email},
        "metadata": {
            "iago_pedido_id": order_id,
            "iago_pedido_numero": order_context["numero"],
            "provider_mode": _sandbox_mode(),
        },
    }
    if settings.mercado_pago_notification_url:
        payload["notification_url"] = settings.mercado_pago_notification_url

    if method == "pix":
        payload["payment_method_id"] = "pix"
        return payload, idempotency_key, external_reference

    card_payload = card_payload or {}
    token = card_payload.get("token")
    payment_method_id = card_payload.get("payment_method_id")
    if not token or not payment_method_id:
        raise HTTPException(status_code=400, detail="Token e bandeira do cartão são obrigatórios.")

    payload.update(
        {
            "token": token,
            "installments": int(card_payload.get("installments") or 1),
            "payment_method_id": payment_method_id,
        }
    )
    if card_payload.get("issuer_id"):
        payload["issuer_id"] = card_payload["issuer_id"]
    if card_payload.get("payer"):
        payload["payer"] = card_payload["payer"]

    return payload, idempotency_key, external_reference


def create_mercado_pago_payment(
    order_context: dict[str, Any],
    method: str,
    card_payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    request_payload, idempotency_key, external_reference = create_payment_payload(
        order_context,
        method,
        card_payload,
    )
    response_payload, response_headers, http_status, elapsed_ms = _json_request(
        "/v1/payments",
        method="POST",
        payload=request_payload,
        idempotency_key=idempotency_key,
    )
    _raise_for_mercado_pago_error("a criação do pagamento", http_status, response_payload)
    transaction_data = (
        response_payload.get("point_of_interaction", {})
        .get("transaction_data", {})
    )

    provider_payment_id = response_payload.get("id")
    provider_status = response_payload.get("status") or ("rejected" if http_status >= 400 else None)
    if not provider_payment_id:
        raise HTTPException(
            status_code=502,
            detail="Mercado Pago criou uma resposta sem ID de pagamento; a tentativa não pode ser sincronizada.",
        )
    logger.info(
        "Mercado Pago payment create: method=%s http_status=%s provider_payment_id=%s provider_status=%s qr_code_base64=%s qr_code=%s qr_code_url=%s",
        method,
        http_status,
        "OK" if provider_payment_id else "VAZIO",
        provider_status or "VAZIO",
        "OK" if transaction_data.get("qr_code_base64") else "VAZIO",
        "OK" if transaction_data.get("qr_code") else "VAZIO",
        "OK" if transaction_data.get("ticket_url") else "VAZIO",
    )
    return {
        "provider_mode": _sandbox_mode(),
        "provider_payment_id": str(provider_payment_id) if provider_payment_id else None,
        "provider_transaction_id": str(response_payload.get("transaction_details", {}).get("transaction_id") or "")
        or None,
        "qr_code_base64": transaction_data.get("qr_code_base64"),
        "qr_code_url": transaction_data.get("ticket_url"),
        "copia_cola": transaction_data.get("qr_code"),
        "external_reference": response_payload.get("external_reference") or external_reference,
        "payment_url": response_payload.get("init_point") or response_payload.get("sandbox_init_point"),
        "expiration_date": response_payload.get("date_of_expiration") or request_payload.get("date_of_expiration"),
        "provider_status": provider_status,
        "request_payload": request_payload,
        "response_payload": response_payload,
        "response_headers": response_headers,
        "http_status": http_status,
        "tempo_resposta_ms": elapsed_ms,
        "idempotency_key": idempotency_key,
        "erro_tecnico": None,
        "erro_negocio": (
            "Mercado Pago criou o Pix, mas não retornou QR Code nem Pix Copia e Cola."
            if method == "pix" and not any([
                transaction_data.get("qr_code_base64"),
                transaction_data.get("qr_code"),
                transaction_data.get("ticket_url"),
            ])
            else None
        ),
    }


def get_mercado_pago_payment(provider_payment_id: str) -> dict[str, Any]:
    response_payload, response_headers, http_status, _elapsed_ms = _json_request(
        f"/v1/payments/{provider_payment_id}",
        method="GET",
    )
    _raise_for_mercado_pago_error("a consulta do pagamento", http_status, response_payload)
    provider_status = _provider_status_for_checkout(response_payload)
    return {
        "provider_status": provider_status,
        "provider_payload": response_payload,
        "response_headers": response_headers,
        "http_status": http_status,
        "erro_tecnico": None if http_status < 500 else response_payload.get("message", "Erro tecnico Mercado Pago."),
        "erro_negocio": (
            "Pix expirado pela data de vencimento retornada pelo Mercado Pago."
            if provider_status == "expired" and response_payload.get("status") != "expired"
            else None
        ),
    }


def cancel_mercado_pago_payment(provider_payment_id: str) -> dict[str, Any]:
    response_payload, response_headers, http_status, elapsed_ms = _json_request(
        f"/v1/payments/{provider_payment_id}",
        method="PUT",
        payload={"status": "cancelled"},
    )
    _raise_for_mercado_pago_error("o cancelamento do pagamento", http_status, response_payload)
    provider_status = response_payload.get("status") or ("cancelled" if http_status < 400 else None)
    logger.info(
        "Mercado Pago payment cancel: http_status=%s provider_payment_id=%s provider_status=%s",
        http_status,
        "OK" if provider_payment_id else "VAZIO",
        provider_status or "VAZIO",
    )
    return {
        "provider_status": provider_status,
        "provider_payload": response_payload,
        "response_headers": response_headers,
        "http_status": http_status,
        "tempo_resposta_ms": elapsed_ms,
        "erro_tecnico": None if http_status < 500 else response_payload.get("message", "Erro tecnico Mercado Pago."),
        "erro_negocio": None if http_status < 400 else response_payload.get("message", "Cancelamento nao aceito pelo Mercado Pago."),
    }
