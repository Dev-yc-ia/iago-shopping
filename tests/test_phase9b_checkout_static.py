from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKOUT_HTML = ROOT / "frontend" / "checkout" / "index.html"
CHECKOUT_JS = ROOT / "frontend" / "features" / "checkout.js"
CORE_JS = ROOT / "frontend" / "core" / "app.js"
CART_JS = ROOT / "frontend" / "features" / "cart.js"
ORDERS_JS = ROOT / "frontend" / "features" / "orders.js"
MAIN_PY = ROOT / "backend" / "main.py"
STYLE_CSS = ROOT / "frontend" / "css" / "style.css"
ANALYTICS_JS = ROOT / "frontend" / "utils" / "analytics.js"
PLANNING = ROOT / "Documentos" / "PLANEJAMENTO_MVP_ATUALIZADO.md"
CHECKLIST = ROOT / "Documentos" / "CHECKLIST_TESTES_FASE9_PAGAMENTOS.md"


def test_phase9b_adds_dedicated_checkout_page_and_route():
    html = CHECKOUT_HTML.read_text(encoding="utf-8")
    core = CORE_JS.read_text(encoding="utf-8")
    main = MAIN_PY.read_text(encoding="utf-8")
    cart = CART_JS.read_text(encoding="utf-8")
    orders = ORDERS_JS.read_text(encoding="utf-8")

    assert 'data-page="checkout"' in html
    assert "data-checkout-root" in html
    assert "data-checkout-summary" in html
    assert "initCheckoutPage" in core
    assert 'page === "checkout"' in core
    assert '"checkout"' in main
    assert "/checkout/?pedido=" in cart
    assert "/checkout/?pedido=" in orders


def test_phase9b_checkout_uses_payment_engine_without_manual_approval():
    checkout = CHECKOUT_JS.read_text(encoding="utf-8")

    required_fragments = [
        "shopping_pedidos_cliente_listar",
        "getPaymentEngineMetadata",
        "startPayment",
        "syncMercadoPagoPayment",
        "cancelPaymentAttempt",
        "mountMercadoPagoPaymentBrick",
        "isMercadoPagoEngine",
        "Pix copia e cola",
        "Copiar código Pix",
        "Código copiado",
        "PIX expirado",
        "checkout-pix-countdown",
        "Pedido criado",
        "Pagamento gerado",
        "Aguardando pagamento",
        "Pagamento confirmado",
        "Pedido confirmado",
        "Gerar novo Pix",
        "Tentar outro pagamento",
        "Cancelar pagamento",
        "Atualizar status",
        "checkout_view",
        "cartao_debito",
        "cartao_credito",
    ]
    for fragment in required_fragments:
        assert fragment in checkout

    assert "Aprovar" not in checkout
    assert "Recusar" not in checkout
    assert "Expirar" not in checkout
    assert "Cancelar pedido" not in checkout
    assert 'rpc("shopping_pagamento_mock_simular"' not in checkout


def test_phase9b_styles_and_docs_are_updated():
    css = STYLE_CSS.read_text(encoding="utf-8")
    analytics = ANALYTICS_JS.read_text(encoding="utf-8")
    planning = PLANNING.read_text(encoding="utf-8")
    checklist = CHECKLIST.read_text(encoding="utf-8")

    for fragment in [
        ".checkout-shell",
        ".checkout-review",
        ".checkout-payment-panel",
        ".checkout-methods",
        ".checkout-pix-qr",
        ".checkout-pix-countdown.is-expired",
        ".checkout-brick",
        ".checkout-cancel-payment",
        ".mercado-pago-brick iframe",
    ]:
        assert fragment in css

    assert '"checkout_view"' in analytics
    assert '"payment_attempt_cancel"' in analytics
    assert '"payment_brick_ready"' in analytics
    assert "| 9 | Pagamentos | Concluída localmente |" in planning
    assert "Fase 9B - Checkout Profissional" in checklist
    assert "Cartão de débito Sandbox" in checklist


def test_phase9b_customizes_payment_brick_and_logs_pix_payload_safely():
    payments = (ROOT / "frontend" / "features" / "payments.js").read_text(encoding="utf-8")
    mercado_pago = (ROOT / "backend" / "services" / "mercado_pago.py").read_text(encoding="utf-8")

    for fragment in [
        "mp.bricks()",
        'bricksBuilder.create("cardPayment"',
        "customVariables",
        "formBackgroundColor",
        "inputBackgroundColor",
        "inputFocusedBoxShadow",
        "inputFocusedBorderWidth",
        "inputVerticalPadding",
        "textPrimaryColor",
        "[IAGO Payment] Card Payment Brick ready",
        "[IAGO Payment] Pix provider response",
    ]:
        assert fragment in payments

    for fragment in [
        "Mercado Pago payment create",
        "qr_code_base64=%s",
        "qr_code=%s",
        "qr_code_url=%s",
        '"provider_status": provider_status',
    ]:
        assert fragment in mercado_pago


def test_phase9b_adds_payment_attempt_cancellation_architecture():
    config = (ROOT / "frontend" / "config" / "app.js").read_text(encoding="utf-8")
    payments = (ROOT / "frontend" / "features" / "payments.js").read_text(encoding="utf-8")
    checkout = CHECKOUT_JS.read_text(encoding="utf-8")
    schemas = (ROOT / "backend" / "schemas" / "payments.py").read_text(encoding="utf-8")
    router = (ROOT / "backend" / "routers" / "payments.py").read_text(encoding="utf-8")
    migration = (ROOT / "sql" / "migrations" / "20260829_012_fase9b_cancelamento_pagamento.sql").read_text(encoding="utf-8")

    assert "paymentCancelEndpoint" in config
    assert "cancelPaymentAttempt" in payments
    assert "shopping_pagamento_cancelar_tentativa_rpc" in payments
    assert "onCancelPayment" in checkout
    assert "stopPolling" in checkout
    assert "PaymentCancelRequest" in schemas
    assert '@router.post("/cancel"' in router
    assert "cancel_mercado_pago_payment" in router
    assert "shopping_pagamento_cancelar_tentativa_rpc" in migration
    assert "payment.checkout.cancelled_by_customer" in migration
    assert "pagamento_status = 'pendente'" in migration
    assert "notify pgrst, 'reload schema'" in migration


def test_web05_frontend_uses_supabase_edge_functions_for_payments():
    config = (ROOT / "frontend" / "config" / "app.js").read_text(encoding="utf-8")
    payments = (ROOT / "frontend" / "features" / "payments.js").read_text(encoding="utf-8")

    assert "https://api.ia-go.api.br" not in config
    assert 'apiBaseUrl: API_BASE_URL' in config
    assert 'apiEndpoint("/api/config/public")' in config
    assert 'paymentEngineEndpoint: "payment-engine"' in config
    assert 'paymentCreateEndpoint: "payment-create"' in config
    assert 'paymentSyncEndpoint: "payment-sync"' in config
    assert 'paymentCancelEndpoint: "payment-cancel"' in config
    assert "supabase.functions.invoke" in payments
    assert 'fetch(APP_CONFIG.paymentEngineEndpoint)' not in payments
    assert 'fetch(endpoint' not in payments


def test_web05_backend_cors_and_env_example_are_production_ready():
    settings = (ROOT / "backend" / "config" / "settings.py").read_text(encoding="utf-8")
    main = MAIN_PY.read_text(encoding="utf-8")
    env_example = (ROOT / ".env.example").read_text(encoding="utf-8")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")

    assert 'PRODUCTION_CORS_ORIGINS = ["https://ia-go.api.br", "https://www.ia-go.api.br"]' in settings
    assert "resolved_cors_origins" in settings
    assert "allow_origins=settings.resolved_cors_origins" in main
    assert 'allow_headers=["Authorization", "Content-Type", "Accept"]' in main
    assert 'ENVIRONMENT="production"' in env_example
    assert 'PAYMENT_PROVIDER="mercado_pago_prod"' in env_example
    assert 'MERCADO_PAGO_NOTIFICATION_URL="https://ualnmcvgddofqvijzfjt.supabase.co/functions/v1/mercado-pago-webhook"' in env_example
    assert "uvicorn backend.main:app --host 0.0.0.0 --port $PORT" in readme


def test_web05_edge_function_structure_and_auth_policy():
    config = (ROOT / "supabase" / "config.toml").read_text(encoding="utf-8")

    for function_name in [
        "payment-engine",
        "payment-create",
        "payment-sync",
        "payment-cancel",
        "mercado-pago-webhook",
    ]:
        assert (ROOT / "supabase" / "functions" / function_name / "index.ts").exists()

    assert "[functions.payment-engine]" in config
    assert "[functions.payment-create]" in config
    assert "[functions.payment-sync]" in config
    assert "[functions.payment-cancel]" in config
    assert "[functions.mercado-pago-webhook]" in config
    assert "verify_jwt = true" in config
    assert config.count("verify_jwt = false") == 2


def test_web05_edge_functions_preserve_rpc_mapping_and_payloads():
    create = (ROOT / "supabase" / "functions" / "payment-create" / "index.ts").read_text(encoding="utf-8")
    sync = (ROOT / "supabase" / "functions" / "payment-sync" / "index.ts").read_text(encoding="utf-8")
    cancel = (ROOT / "supabase" / "functions" / "payment-cancel" / "index.ts").read_text(encoding="utf-8")
    webhook = (ROOT / "supabase" / "functions" / "mercado-pago-webhook" / "index.ts").read_text(encoding="utf-8")
    mp = (ROOT / "supabase" / "functions" / "_shared" / "mercado_pago.ts").read_text(encoding="utf-8")
    sb = (ROOT / "supabase" / "functions" / "_shared" / "supabase.ts").read_text(encoding="utf-8")

    for fragment in [
        "shopping_pagamento_checkout_context",
        "shopping_pagamento_mercado_pago_registrar_checkout",
        "shopping_pagamento_mercado_pago_sincronizar_consulta",
        "p_provider_payment_id",
        "p_provider_transaction_id",
        "p_qr_code_base64",
        "p_qr_code_url",
        "p_copia_cola",
        "p_external_reference",
        "p_payment_url",
        "p_expiration_date",
        "p_idempotency_key",
        "p_request_payload",
        "p_response_payload",
    ]:
        assert fragment in create

    assert "shopping_pagamento_mercado_pago_sincronizar_consulta" in sync
    assert "shopping_pagamento_cancelar_tentativa_rpc" in cancel
    assert "shopping_pagamento_mercado_pago_processar_webhook" in webhook
    assert "adminSupabaseClient()" in webhook
    assert "userSupabaseClient(request)" in create
    assert "userSupabaseClient(request)" in sync
    assert "userSupabaseClient(request)" in cancel
    assert "supabaseSecretKey" in sb

    for fragment in [
        "/v1/payments",
        "x-idempotency-key",
        "external_reference",
        "payment_method_id = \"pix\"",
        "date_of_expiration",
        "token",
        "installments",
        "provider_mode",
    ]:
        assert fragment in mp


def test_web05_cors_engine_and_webhook_do_not_expose_secrets():
    cors = (ROOT / "supabase" / "functions" / "_shared" / "cors.ts").read_text(encoding="utf-8")
    mp = (ROOT / "supabase" / "functions" / "_shared" / "mercado_pago.ts").read_text(encoding="utf-8")
    engine = (ROOT / "supabase" / "functions" / "payment-engine" / "index.ts").read_text(encoding="utf-8")
    webhook = (ROOT / "supabase" / "functions" / "mercado-pago-webhook" / "index.ts").read_text(encoding="utf-8")
    public_json = (ROOT / "frontend" / "config" / "public.json").read_text(encoding="utf-8")

    assert "https://ia-go.api.br" in cors
    assert "https://www.ia-go.api.br" in cors
    assert "localhost" in cors
    assert "authorization, apikey, content-type, x-client-info" in cors
    assert "withCors" in engine
    assert "OPTIONS" in cors

    assert "MERCADO_PAGO_WEBHOOK_SECRET" in mp
    assert "Webhook Mercado Pago sem assinatura válida" in mp
    assert "Assinatura do webhook Mercado Pago inválida" in mp
    assert "timingSafeEqual" in mp
    assert "verifyMercadoPagoWebhook(request, payload)" in webhook

    assert "MERCADO_PAGO_ACCESS_TOKEN" not in public_json
    assert "MERCADO_PAGO_WEBHOOK_SECRET" not in public_json
    assert "SUPABASE_SERVICE_ROLE_KEY" not in public_json
    assert "MERCADO_PAGO_ACCESS_TOKEN" not in engine
    assert "MERCADO_PAGO_WEBHOOK_SECRET" not in engine
