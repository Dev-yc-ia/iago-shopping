from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"
MIGRATION = ROOT / "sql" / "migrations" / "20260909_018_web10_parceiros_entrega_recebimento_repasse.sql"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web10_sql_models_partner_snapshot_fulfillment_and_payout():
    migration = read(MIGRATION)

    for fragment in [
        "add column if not exists parceiro_user_id uuid references public.shopping_perfis(user_id)",
        "add column if not exists valor_repasse_parceiro numeric(12, 2)",
        "parceiro_user_id_snapshot",
        "valor_repasse_unitario_snapshot",
        "valor_repasse_total_snapshot",
        "endereco_entrega_snapshot jsonb",
        "fulfillment_status text not null default 'pendente_pagamento'",
        "create table if not exists public.shopping_pedido_entregas",
        "constraint shopping_pedido_entregas_pedido_parceiro_unique unique (pedido_id, parceiro_user_id)",
        "'bloqueado'",
        "'elegivel'",
        "'pago'",
    ]:
        assert fragment in migration


def test_web10_sql_creates_deliveries_after_approved_payment_without_financial_transfer():
    migration = read(MIGRATION)

    for fragment in [
        "shopping_pagamento_criar_entregas_pedido",
        "coalesce(p_aprovado_em, now()) + interval '12 days'",
        "coalesce(p_aprovado_em, now()) + interval '20 days'",
        "on conflict on constraint shopping_pedido_entregas_pedido_parceiro_unique",
        "perform public.shopping_pagamento_criar_entregas_pedido(v_pagamento.pedido_id, v_aprovado_em)",
        "shopping_pagamento_aplicar_resultado_provider",
        "shopping_pagamento_mock_simular",
        "fulfillment_created",
    ]:
        assert fragment in migration

    forbidden = ["pix automatico", "split payment", "transferencia bancaria", "mercado pago transfer"]
    lowered = migration.lower()
    for fragment in forbidden:
        assert fragment not in lowered


def test_web10_sql_scopes_partner_and_customer_actions_server_side():
    migration = read(MIGRATION)

    for fragment in [
        "shopping_admin_listar_parceiros_ativos",
        "Somente master ativo pode listar parceiros",
        "shopping_is_master_or_funcionario",
        "drop policy if exists shopping_pedidos_select_own_or_admin",
        "shopping_pedido_itens.parceiro_user_id_snapshot = auth.uid()",
        "drop policy if exists shopping_pagamentos_select_own_or_admin",
        "shopping_parceiro_listar_pedidos",
        "where spe.parceiro_user_id = v_perfil.user_id",
        "and sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento",
        "shopping_parceiro_confirmar_entrega",
        "Entrega nao pertence ao parceiro autenticado.",
        "status <> 'aguardando_parceiro'::public.shopping_status_entrega",
        "shopping_cliente_confirmar_recebimento",
        "v_pedido.user_id <> v_actor",
        "status not in (",
        "'enviado'::public.shopping_status_entrega",
        "'entregue_pessoalmente'::public.shopping_status_entrega",
        "repasse_status = 'elegivel'::public.shopping_status_repasse",
        "order_fulfillment_completed",
    ]:
        assert fragment in migration


def test_web10_frontend_adds_commercial_product_fields_and_role_aware_admin():
    html = read(FRONTEND / "admin" / "index.html")
    admin = read(FRONTEND / "features" / "admin.js")
    products = read(FRONTEND / "features" / "adminProducts.js")
    admin_orders = read(FRONTEND / "features" / "adminOrders.js")

    for fragment in [
        "Parceiro responsável",
        "Repasse ao parceiro",
        "data-product-partner",
        "data-admin-master-area",
        "data-admin-payments-area",
        "shopping_admin_listar_parceiros_ativos",
        "p_parceiro_user_id",
        "p_valor_repasse_parceiro",
        "Repasse ao parceiro não pode ser maior que o preço final.",
        "profile.papel === \"master\"",
        "role === \"parceiro\"",
        "shopping_parceiro_listar_pedidos",
        "shopping_parceiro_confirmar_entrega",
        "Confirmar entrega pessoal",
    ]:
        assert fragment in html + admin + products + admin_orders


def test_web10_frontend_customer_receipt_flow_and_checkout_copy():
    orders = read(FRONTEND / "features" / "orders.js")
    checkout = read(FRONTEND / "features" / "checkout.js")

    for fragment in [
        "Pagamento aprovado. Seu pedido foi encaminhado ao parceiro responsável.",
        "Confirmar recebimento",
        "shopping_cliente_confirmar_recebimento",
        "Confirma que recebeu este produto/pacote?",
        "Parceiro confirmou envio",
        "Parceiro confirmou entrega pessoal",
        "Recebimento confirmado",
        "Pagamento confirmado. Seu pedido foi encaminhado ao parceiro responsável. Acompanhe a entrega em Meus Pedidos.",
        "Aguardando parceiro",
    ]:
        assert fragment in orders + checkout

    assert "Pedido confirmado" not in checkout
