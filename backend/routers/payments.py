import hmac
import json
import logging
from hashlib import sha256
from typing import Any

from fastapi import APIRouter, Header, HTTPException, Request

from backend.config.settings import get_settings
from backend.schemas.payments import (
    MockPaymentConfig,
    PaymentCancelRequest,
    PaymentCreateRequest,
    PaymentCreateResponse,
    PaymentEngineResponse,
    PaymentScenario,
    PaymentSyncRequest,
    PaymentWebhookResponse,
)
from backend.services.mercado_pago import (
    cancel_mercado_pago_payment,
    create_mercado_pago_payment,
    get_mercado_pago_payment,
)
from backend.services.payment_engine import MockPaymentConfig as EngineMockPaymentConfig
from backend.services.payment_engine import get_payment_provider
from backend.services.supabase_rpc import call_supabase_rpc

try:
    from mercadopago.webhook import WebhookSignatureValidator
except Exception:
    WebhookSignatureValidator = None


router = APIRouter(prefix="/api/payments", tags=["payments"])
logger = logging.getLogger("iago.shopping.payments")


def _as_log_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, default=str)


def _bearer_token(authorization: str | None) -> str:
    if not authorization:
        raise HTTPException(status_code=401, detail="Sessão obrigatória para operação de pagamento.")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(status_code=401, detail="Token de sessão inválido.")
    return token.strip()


def _first_row(value: Any) -> dict[str, Any]:
    if isinstance(value, list):
        return value[0] if value else {}
    return value or {}


def _is_mercado_pago_provider() -> bool:
    return get_settings().payment_provider.strip().lower() in {
        "mercado_pago",
        "mercado_pago_sandbox",
        "mercado_pago_prod",
    }


def _webhook_headers(headers: dict[str, str]) -> dict[str, str]:
    return {
        key.lower(): value
        for key, value in headers.items()
        if key.lower().startswith(("x-", "content-", "user-agent"))
    }


def _extract_signature_part(signature_header: str, key: str) -> str | None:
    for part in signature_header.split(","):
        name, _, value = part.strip().partition("=")
        if name == key and value:
            return value
    return None


def _verify_mercado_pago_webhook(payload: dict[str, Any], headers: dict[str, str]) -> None:
    settings = get_settings()
    if not settings.mercado_pago_webhook_secret:
        return

    signature_header = headers.get("x-signature", "")
    request_id = headers.get("x-request-id", "")
    timestamp = _extract_signature_part(signature_header, "ts")
    received_signature = _extract_signature_part(signature_header, "v1")
    data_id = str(payload.get("data", {}).get("id") or payload.get("id") or "")

    if not (request_id and timestamp and received_signature and data_id):
        raise HTTPException(status_code=401, detail="Webhook Mercado Pago sem assinatura válida.")

    if WebhookSignatureValidator is not None:
        try:
            if WebhookSignatureValidator.validate(
                signature_header,
                request_id,
                data_id,
                settings.mercado_pago_webhook_secret,
            ):
                return
        except Exception:
            pass

    manifest = f"id:{data_id};request-id:{request_id};ts:{timestamp};"
    expected = hmac.new(
        settings.mercado_pago_webhook_secret.encode("utf-8"),
        manifest.encode("utf-8"),
        sha256,
    ).hexdigest()

    if not hmac.compare_digest(expected, received_signature):
        raise HTTPException(status_code=401, detail="Assinatura do webhook Mercado Pago inválida.")


@router.get("/engine", response_model=PaymentEngineResponse)
def payment_engine() -> PaymentEngineResponse:
    settings = get_settings()
    engine_mock_config = EngineMockPaymentConfig(
        scenario=settings.mock_payment_scenario,
        delay_ms=settings.mock_payment_delay_ms,
        timeout_ms=settings.mock_payment_timeout_ms,
        expiration_ms=settings.mock_payment_expiration_ms,
    )
    provider = get_payment_provider(settings.payment_provider, engine_mock_config)
    metadata = provider.metadata()
    return PaymentEngineResponse(
        provider=metadata.provider,
        mode=metadata.mode,
        methods=metadata.methods,
        future_provider=metadata.future_provider,
        webhook_ready=metadata.webhook_ready,
        public_key=metadata.public_key,
        provider_mode=metadata.provider_mode,
        poll_interval_ms=metadata.poll_interval_ms,
        scenarios=[
            PaymentScenario(
                status=scenario.status,
                label=scenario.label,
                description=scenario.description,
            )
            for scenario in metadata.scenarios
        ],
        mock_config=MockPaymentConfig(
            scenario=metadata.mock_config.scenario,
            delay_ms=metadata.mock_config.delay_ms,
            timeout_ms=metadata.mock_config.timeout_ms,
            expiration_ms=metadata.mock_config.expiration_ms,
        ) if metadata.mock_config else None,
    )


@router.post("/create", response_model=PaymentCreateResponse)
def create_payment(
    payload: PaymentCreateRequest,
    authorization: str | None = Header(default=None),
) -> PaymentCreateResponse:
    if not _is_mercado_pago_provider():
        raise HTTPException(status_code=400, detail="Provider ativo não usa checkout externo.")

    user_jwt = _bearer_token(authorization)
    context = _first_row(
        call_supabase_rpc(
            "shopping_pagamento_checkout_context",
            {"p_pedido_id": payload.order_id},
            user_jwt=user_jwt,
        )
    )
    if not context:
        raise HTTPException(status_code=404, detail="Pedido não encontrado para checkout.")

    provider_result = create_mercado_pago_payment(
        context,
        payload.method,
        payload.card_payload,
    )

    payment = call_supabase_rpc(
        "shopping_pagamento_mercado_pago_registrar_checkout",
        {
            "p_pedido_id": payload.order_id,
            "p_metodo": payload.method,
            "p_provider_mode": provider_result["provider_mode"],
            "p_provider_payment_id": provider_result["provider_payment_id"],
            "p_provider_transaction_id": provider_result["provider_transaction_id"],
            "p_qr_code_base64": provider_result["qr_code_base64"],
            "p_qr_code_url": provider_result["qr_code_url"],
            "p_copia_cola": provider_result["copia_cola"],
            "p_external_reference": provider_result["external_reference"],
            "p_payment_url": provider_result["payment_url"],
            "p_expiration_date": provider_result["expiration_date"],
            "p_provider_status": provider_result["provider_status"],
            "p_idempotency_key": provider_result["idempotency_key"],
            "p_request_payload": provider_result["request_payload"],
            "p_response_payload": provider_result["response_payload"],
            "p_response_headers": provider_result["response_headers"],
            "p_tempo_resposta_ms": provider_result["tempo_resposta_ms"],
            "p_http_status": provider_result["http_status"],
            "p_erro_tecnico": provider_result["erro_tecnico"],
            "p_erro_negocio": provider_result["erro_negocio"],
        },
        user_jwt=user_jwt,
    )
    payment_row = _first_row(payment)

    if provider_result["provider_status"]:
        payment_row = _first_row(
            call_supabase_rpc(
                "shopping_pagamento_mercado_pago_sincronizar_consulta",
                {
                    "p_pagamento_id": payment_row["id"],
                    "p_provider_status": provider_result["provider_status"],
                    "p_provider_payload": provider_result["response_payload"],
                    "p_response_headers": provider_result["response_headers"],
                    "p_http_status": provider_result["http_status"],
                    "p_erro_tecnico": provider_result["erro_tecnico"],
                    "p_erro_negocio": provider_result["erro_negocio"],
                },
                user_jwt=user_jwt,
            )
        )

    return PaymentCreateResponse(payment=payment_row, provider_payload=provider_result["response_payload"])


@router.post("/sync", response_model=PaymentCreateResponse)
def sync_payment(
    payload: PaymentSyncRequest,
    authorization: str | None = Header(default=None),
) -> PaymentCreateResponse:
    if not _is_mercado_pago_provider():
        raise HTTPException(status_code=400, detail="Provider ativo não usa sincronização externa.")

    user_jwt = _bearer_token(authorization)
    if not payload.provider_payment_id:
        raise HTTPException(status_code=400, detail="Pagamento ainda não possui ID no provider.")

    provider_result = get_mercado_pago_payment(payload.provider_payment_id)
    payment = call_supabase_rpc(
        "shopping_pagamento_mercado_pago_sincronizar_consulta",
        {
            "p_pagamento_id": payload.payment_id,
            "p_provider_status": provider_result["provider_status"],
            "p_provider_payload": provider_result["provider_payload"],
            "p_response_headers": provider_result["response_headers"],
            "p_http_status": provider_result["http_status"],
            "p_erro_tecnico": provider_result["erro_tecnico"],
            "p_erro_negocio": provider_result["erro_negocio"],
        },
        user_jwt=user_jwt,
    )
    return PaymentCreateResponse(payment=_first_row(payment), provider_payload=provider_result["provider_payload"])


@router.post("/cancel", response_model=PaymentCreateResponse)
def cancel_payment(
    payload: PaymentCancelRequest,
    authorization: str | None = Header(default=None),
) -> PaymentCreateResponse:
    user_jwt = _bearer_token(authorization)
    provider_result: dict[str, Any] | None = None

    if _is_mercado_pago_provider() and payload.provider_payment_id:
        provider_result = cancel_mercado_pago_payment(payload.provider_payment_id)
        provider_status = (provider_result.get("provider_status") or "").lower()
        if provider_status and provider_status not in {"cancelled", "canceled"}:
            call_supabase_rpc(
                "shopping_pagamento_mercado_pago_sincronizar_consulta",
                {
                    "p_pagamento_id": payload.payment_id,
                    "p_provider_status": provider_result["provider_status"],
                    "p_provider_payload": provider_result["provider_payload"],
                    "p_response_headers": provider_result["response_headers"],
                    "p_http_status": provider_result["http_status"],
                    "p_erro_tecnico": provider_result["erro_tecnico"],
                    "p_erro_negocio": provider_result["erro_negocio"],
                },
                user_jwt=user_jwt,
            )
            raise HTTPException(
                status_code=409,
                detail=(
                    "Mercado Pago não confirmou o cancelamento. "
                    f"Status atual do provider: {provider_result['provider_status'] or 'indefinido'}."
                ),
            )

    payment = call_supabase_rpc(
        "shopping_pagamento_cancelar_tentativa_rpc",
        {
            "p_pagamento_id": payload.payment_id,
            "p_payload": {
                "provider": "mercado_pago" if _is_mercado_pago_provider() else "mock",
                "provider_payment_id": payload.provider_payment_id,
                "provider_cancel_response": provider_result or {},
            },
        },
        user_jwt=user_jwt,
    )
    return PaymentCreateResponse(
        payment=_first_row(payment),
        provider_payload=provider_result["provider_payload"] if provider_result else None,
    )


@router.post("/webhooks/mercado-pago", response_model=PaymentWebhookResponse)
async def mercado_pago_webhook(request: Request) -> PaymentWebhookResponse:
    raw_body = await request.body()
    try:
        payload = json.loads(raw_body.decode("utf-8") or "{}")
    except json.JSONDecodeError as error:
        logger.exception(
            "Mercado Pago WEBHOOK invalid JSON\n%s",
            _as_log_json({
                "endpoint": "/api/payments/webhooks/mercado-pago",
                "method": "POST",
                "raw_body": raw_body.decode("utf-8", errors="replace"),
            }),
        )
        raise HTTPException(status_code=400, detail="Webhook Mercado Pago inválido.") from error

    headers = _webhook_headers(dict(request.headers.items()))
    logger.info(
        "Mercado Pago WEBHOOK received\n%s",
        _as_log_json({
            "endpoint": "/api/payments/webhooks/mercado-pago",
            "method": "POST",
            "headers": headers,
            "payload": payload,
            "provider_payment_id": str(payload.get("data", {}).get("id") or payload.get("id") or "VAZIO"),
            "type": payload.get("type") or "VAZIO",
            "action": payload.get("action") or "VAZIO",
        }),
    )
    try:
        _verify_mercado_pago_webhook(payload, headers)
    except HTTPException:
        logger.exception(
            "Mercado Pago WEBHOOK verification failed\n%s",
            _as_log_json({
                "endpoint": "/api/payments/webhooks/mercado-pago",
                "method": "POST",
                "headers": headers,
                "payload": payload,
            }),
        )
        raise

    provider_payment_id = str(payload.get("data", {}).get("id") or payload.get("id") or "")
    if not provider_payment_id:
        logger.error(
            "Mercado Pago WEBHOOK missing payment id\n%s",
            _as_log_json({
                "endpoint": "/api/payments/webhooks/mercado-pago",
                "headers": headers,
                "payload": payload,
            }),
        )
        raise HTTPException(status_code=400, detail="Webhook Mercado Pago sem ID de pagamento.")

    provider_result = get_mercado_pago_payment(provider_payment_id)
    call_supabase_rpc(
        "shopping_pagamento_mercado_pago_processar_webhook",
        {
            "p_provider_payment_id": provider_payment_id,
            "p_provider_status": provider_result["provider_status"],
            "p_payload_bruto": payload,
            "p_payload_tratado": provider_result["provider_payload"],
            "p_headers": headers,
        },
        service_role=True,
    )
    logger.info(
        "Mercado Pago WEBHOOK processed\n%s",
        _as_log_json({
            "endpoint": "/api/payments/webhooks/mercado-pago",
            "provider_payment_id": provider_payment_id,
            "provider_status": provider_result["provider_status"] or "VAZIO",
            "http_status": provider_result["http_status"],
        }),
    )

    return PaymentWebhookResponse(
        received=True,
        provider_payment_id=provider_payment_id,
        status=provider_result["provider_status"],
    )
