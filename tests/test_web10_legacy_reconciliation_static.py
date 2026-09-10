from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "sql" / "migrations" / "20260910_019_web10_reconciliar_pedido_pago_legado.sql"
PARTNER_MIGRATION = ROOT / "sql" / "migrations" / "20260910_020_web10_parceiro_autorreconciliar_entregas_legadas.sql"
PARTNER_LIST_MIGRATION = ROOT / "sql" / "migrations" / "20260910_021_web10_listagem_parceiro_autocorrige_pedido_pago.sql"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web10_legacy_reconciliation_migration_exists_for_target_sku():
    migration = read(MIGRATION)

    for fragment in [
        "TEN-HOCKS-010",
        "shopping_admin_diagnosticar_pedido_pago_legado",
        "shopping_admin_reconciliar_pedido_pago_legado",
        "Informe SKU ou pedido_id para evitar diagnostico amplo.",
        "Informe SKU ou pedido_id para evitar backfill amplo.",
        "Somente master ativo pode reconciliar pedido pago legado.",
    ]:
        assert fragment in migration


def test_web10_legacy_reconciliation_is_idempotent_and_does_not_reprocess_payment_or_stock():
    migration = read(MIGRATION)
    lowered = migration.lower()

    for fragment in [
        "on conflict on constraint shopping_pedido_entregas_pedido_parceiro_unique",
        "do nothing",
        "get diagnostics v_snapshot_rows = row_count",
        "v_snapshot_preenchido := v_snapshot_rows > 0",
        "parceiro_user_id_snapshot = coalesce(parceiro_user_id_snapshot, v_item.produto_parceiro_user_id)",
        "valor_repasse_unitario_snapshot = coalesce(valor_repasse_unitario_snapshot, v_item.produto_repasse)",
        "valor_repasse_total_snapshot = coalesce(",
    ]:
        assert fragment in migration

    for forbidden in [
        "shopping_pagamento_mock_simular(",
        "shopping_pagamento_aplicar_resultado_provider(",
        "shopping_pagamento_criar_entregas_pedido(",
        "shopping_pagamento_mercado_pago_registrar_checkout(",
        "shopping_pagamento_mercado_pago_processar_webhook(",
        "shopping_estoque_movimentos",
    ]:
        assert forbidden not in lowered


def test_web10_legacy_reconciliation_preserves_business_rules_and_audit():
    migration = read(MIGRATION)

    for fragment in [
        "sp.status <> 'cancelado'::public.shopping_status_pedido",
        "sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento",
        "spr.parceiro_user_id is not null",
        "spr.valor_repasse_parceiro <= spi.preco_unitario",
        "spar.papel = 'parceiro'::public.shopping_papel",
        "spar.status_ativacao = 'ativo'::public.shopping_status_ativacao",
        "spi.parceiro_user_id_snapshot is null",
        "or spi.parceiro_user_id_snapshot = spr.parceiro_user_id",
        "'aguardando_parceiro'::public.shopping_status_entrega",
        "v_item.pagamento_aprovado_em + interval '12 days'",
        "v_item.pagamento_aprovado_em + interval '20 days'",
        "'bloqueado'::public.shopping_status_repasse",
        "'web10_legacy_order_reconciled'",
        "'repasse_snapshot'",
        "'pagamento_aprovado_em'",
        "'timestamp_reconciliacao'",
        "'origem', 'backfill WEB-10'",
    ]:
        assert fragment in migration


def test_web10_partner_self_reconciliation_scopes_by_authenticated_partner():
    migration = read(PARTNER_MIGRATION)

    for fragment in [
        "shopping_parceiro_reconciliar_pedidos_pagos_legados",
        "shopping_parceiro_ativo_assert(auth.uid())",
        "spr.parceiro_user_id = v_perfil.user_id",
        "spe.parceiro_user_id = v_perfil.user_id",
        "sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento",
        "sp.status <> 'cancelado'::public.shopping_status_pedido",
        "on conflict on constraint shopping_pedido_entregas_pedido_parceiro_unique",
        "'aguardando_parceiro'::public.shopping_status_entrega",
        "'bloqueado'::public.shopping_status_repasse",
        "'web10_legacy_order_reconciled'",
        "'origem', 'autorreconciliacao parceiro WEB-10'",
    ]:
        assert fragment in migration


def test_web10_partner_self_reconciliation_keeps_payment_and_stock_untouched():
    migration = read(PARTNER_MIGRATION).lower()

    for fragment in [
        "shopping_pagamento_mock_simular(",
        "shopping_pagamento_aplicar_resultado_provider(",
        "shopping_pagamento_criar_entregas_pedido(",
        "shopping_pagamento_mercado_pago_registrar_checkout(",
        "shopping_pagamento_mercado_pago_processar_webhook(",
        "shopping_estoque_movimentos",
    ]:
        assert fragment not in migration


def test_web10_partner_listing_self_heals_legacy_paid_order_before_rendering_buttons():
    migration = read(PARTNER_LIST_MIGRATION)

    for fragment in [
        "create or replace function public.shopping_parceiro_listar_pedidos()",
        "perform public.shopping_parceiro_reconciliar_pedidos_pagos_legados();",
        "sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento",
        "sp.status <> 'cancelado'::public.shopping_status_pedido",
        "sp.fulfillment_status = 'pendente_pagamento'",
        "set fulfillment_status = 'em_andamento'",
        "and pagamento_status = 'aprovado'::public.shopping_status_pagamento",
        "'origem', 'autocorrecao listagem parceiro WEB-10'",
        "Lista pedidos pagos do parceiro autenticado e autocorrige entregas legadas antes da leitura.",
    ]:
        assert fragment in migration


def test_web10_partner_listing_self_heal_does_not_invent_paid_order_status_or_touch_payment_stock():
    migration = read(PARTNER_LIST_MIGRATION).lower()

    assert "set status = 'aprovado'" not in migration
    assert "alter type public.shopping_status_pedido add value" not in migration

    for fragment in [
        "shopping_pagamento_mock_simular(",
        "shopping_pagamento_aplicar_resultado_provider(",
        "shopping_pagamento_criar_entregas_pedido(",
        "shopping_pagamento_mercado_pago_registrar_checkout(",
        "shopping_pagamento_mercado_pago_processar_webhook(",
        "shopping_estoque_movimentos",
    ]:
        assert fragment not in migration
