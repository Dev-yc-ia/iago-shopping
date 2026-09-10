from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"
MIGRATION = ROOT / "sql" / "migrations" / "20260909_017_web09_pedidos_cancelamento.sql"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web09_sql_preserves_global_number_and_returns_customer_number():
    migration = read(MIGRATION)

    for fragment in [
        "preserva shopping_pedidos.numero como identificador tecnico global",
        "add column if not exists numero_cliente bigint",
        "public.shopping_pedido_numero_cliente",
        "sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento",
        "coalesce(sp.pagamento_confirmado_em, sp.atualizado_em, sp.criado_em)",
        "update public.shopping_pedidos sp",
        "where sp.numero_cliente is null",
        "and sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento",
        "public.shopping_pedido_numero_cliente(sp.id) as numero_cliente",
        "numero bigint",
        "numero_cliente bigint",
        "shopping_pagamento_checkout_context",
    ]:
        assert fragment in migration


def test_web09_sql_adds_customer_and_master_cancellation_with_audit():
    migration = read(MIGRATION)

    for fragment in [
        "add column if not exists cancelado_em timestamptz",
        "add column if not exists cancelado_por_user_id uuid references auth.users(id)",
        "add column if not exists cancelado_por_tipo text",
        "add column if not exists motivo_cancelamento text",
        "shopping_pedido_cliente_cancelar",
        "shopping_admin_cancelar_pedido",
        "v_actor uuid := auth.uid()",
        "Pedido nao pertence ao usuario autenticado.",
        "Somente master ativo pode cancelar pedido de cliente.",
        "Motivo obrigatorio para cancelamento master.",
        "Pedido aprovado nao pode ser cancelado sem fluxo de estorno.",
        "Cancele a tentativa de pagamento ativa antes de cancelar o pedido.",
        "status = 'cancelado'::public.shopping_status_pedido",
        "pagamento_status = 'cancelado'::public.shopping_status_pagamento",
        "pedido.cancelado.cliente",
        "pedido.cancelado.master",
        "shopping_auditoria",
        "grant execute on function public.shopping_pedido_cliente_cancelar(uuid, text) to authenticated",
        "grant execute on function public.shopping_admin_cancelar_pedido(uuid, text) to authenticated",
    ]:
        assert fragment in migration


def test_web09_sql_blocks_late_payment_approval_for_cancelled_order():
    migration = read(MIGRATION)

    for fragment in [
        "shopping_pagamento_guard_pedido_cancelado",
        "before insert or update of status on public.shopping_pagamentos",
        "'aprovado'::public.shopping_status_pagamento",
        "sp.status = 'cancelado'::public.shopping_status_pedido",
        "sp.pagamento_status = 'cancelado'::public.shopping_status_pagamento",
        "Pedido cancelado nao aceita nova tentativa ou aprovacao de pagamento.",
        "and sp.status <> 'cancelado'::public.shopping_status_pedido",
        "and sp.pagamento_status <> 'cancelado'::public.shopping_status_pagamento",
    ]:
        assert fragment in migration


def test_web09_frontend_uses_customer_number_and_keeps_internal_reference():
    orders = read(FRONTEND / "features" / "orders.js")
    checkout = read(FRONTEND / "features" / "checkout.js")
    admin_orders = read(FRONTEND / "features" / "adminOrders.js")

    for fragment in [
        "const internalNumber = order.numero",
        "internalNumber,",
        "number: order.numero_cliente || internalNumber",
        "Pedido #${order.number}",
        "Ref. interna #${order.internalNumber}",
    ]:
        assert fragment in orders + checkout + admin_orders


def test_web09_frontend_adds_customer_and_master_cancel_actions():
    orders = read(FRONTEND / "features" / "orders.js")
    admin = read(FRONTEND / "features" / "admin.js")
    admin_orders = read(FRONTEND / "features" / "adminOrders.js")
    css = read(FRONTEND / "css" / "style.css")

    for fragment in [
        "cancelPaymentAttempt(order, paymentEngine)",
        "shopping_pedido_cliente_cancelar",
        "Tem certeza que deseja cancelar este pedido?",
        "Cancelado pelo cliente",
        "order.status !== \"cancelado\" && order.paymentStatus !== \"aprovado\"",
        "initAdminOrders({ role: profile.papel, isMaster: profile.papel === \"master\" })",
        "shopping_admin_cancelar_pedido",
        "Motivo do cancelamento:",
        "Informe o motivo para cancelar como master.",
        "return isMaster && order.status !== \"cancelado\" && order.paymentStatus !== \"aprovado\"",
        "Pedido cancelado",
        ".order-cancel-button",
    ]:
        assert fragment in orders + admin + admin_orders + css


def test_web09_admin_link_is_hidden_until_authenticated_admin_navigation_runs():
    pages = [
        "index.html",
        "login/index.html",
        "catalogo/index.html",
        "produto/index.html",
        "carrinho/index.html",
        "checkout/index.html",
        "pedidos/index.html",
        "dados-pessoais/index.html",
        "recuperar-senha/index.html",
        "nova-senha/index.html",
        "admin/index.html",
    ]

    for page in pages:
        html = read(FRONTEND / page)
        assert 'href="/admin/"' in html
        assert 'href="/admin/" hidden' in html or 'href="/admin/" aria-current="page" hidden' in html
