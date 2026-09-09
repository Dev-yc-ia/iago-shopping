from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"
MIGRATION = ROOT / "sql" / "migrations" / "20260909_015_web07_sku_variacoes_estoque.sql"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web07_sql_generates_sku_atomically_and_reuses_variations():
    migration = read(MIGRATION)

    for fragment in [
        "shopping_sku_codigo_categoria",
        "when 'tenis' then 'TEN'",
        "when 'cameras-acessorios' then 'CAM'",
        "shopping_gerar_sku_produto",
        "pg_advisory_xact_lock",
        "max((regexp_match",
        "shopping_admin_salvar_produto_com_variacoes",
        "shopping_admin_sincronizar_variacoes_produto",
        "shopping_produto_variacoes",
        "idx_shopping_produto_variacoes_nome_ativo_unique",
        "v_variacao.estoque_atual < v_item.quantidade",
        "notify pgrst, 'reload schema'",
    ]:
        assert fragment in migration

    assert "count(*) + 1" not in migration.lower()


def test_web07_cart_and_order_preserve_variation_identity():
    migration = read(MIGRATION)
    cart = read(FRONTEND / "features" / "cart.js")
    checkout = read(FRONTEND / "features" / "checkout.js")
    orders = read(FRONTEND / "features" / "orders.js")

    for fragment in [
        "add column if not exists variacao_id",
        "idx_shopping_carrinho_itens_unique_produto_variacao",
        "p_variacao_id uuid default null",
        "Selecione uma variacao antes de adicionar ao carrinho.",
        "Variacao do carrinho indisponivel para pedido.",
        "'variacao_id', spi.variacao_id",
        "'variacao_nome', spv.nome_variacao",
        "p_variacao_id: variationId",
        "variationName",
    ]:
        assert fragment in migration + cart + checkout + orders


def test_web07_frontend_removes_manual_sku_and_adds_variation_controls():
    html = read(FRONTEND / "admin" / "index.html")
    admin = read(FRONTEND / "features" / "adminProducts.js")
    product = read(FRONTEND / "features" / "product.js")
    card = read(FRONTEND / "ui" / "productCard.js")
    css = read(FRONTEND / "css" / "style.css")
    products = read(FRONTEND / "config" / "products.js")

    for fragment in [
        "SKU gerado automaticamente ao salvar",
        "data-variation-rows",
        "data-variation-add",
        "shopping_admin_salvar_produto_com_variacoes",
        "readVariationRows",
        "variationTotal",
        "availableVariations",
        "product-variation-chips",
        "catalog-variation-option",
        "availability.textContent = `${variation.stock} un.`",
        "product-variation-selector",
        "Selecione um tamanho",
        "addProductToCart(product.id, 1, selectedVariation?.id || null)",
        ".variation-editor__row",
        ".variation-option.is-selected",
    ]:
        assert fragment in html + admin + product + card + css + products

    assert 'id="product-sku" name="sku" type="text"' not in html
    assert ".product-card:hover .product-variation-chips" not in css
