from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"
MIGRATION = ROOT / "sql" / "migrations" / "20260910_023_web13_admin_modular_role_based.sql"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web13_admin_has_physical_modular_routes_and_shell():
    admin_html = read(FRONTEND / "admin" / "index.html")
    admin_js = read(FRONTEND / "features" / "admin.js")
    backend = read(ROOT / "backend" / "main.py")

    for route in [
        "produtos/index.html",
        "produtos/novo/index.html",
        "produtos/editar/index.html",
        "pedidos/index.html",
        "entregas/index.html",
        "parceiros/index.html",
        "solicitacoes/index.html",
        "perfis/index.html",
        "pagamentos/index.html",
    ]:
        assert (FRONTEND / "admin" / route).exists()

    for fragment in [
        'data-admin-root',
        'href="/admin/" aria-current="page" hidden',
        'path: "/admin/produtos/"',
        'path: "/admin/produtos/novo/"',
        'path: "/admin/produtos/editar/"',
        'path: "/admin/pedidos/"',
        'path: "/admin/entregas/"',
        'path: "/admin/parceiros/"',
        'path: "/admin/solicitacoes/"',
        'path: "/admin/perfis/"',
        'path: "/admin/pagamentos/"',
        'data-admin-menu-toggle',
        'iago-shopping-admin-nav-collapsed',
        'admin-nav-collapsed',
        'Recolher menu admin',
        'Expandir menu admin',
        'aria-current="page"',
        '@app.get("/admin/{module_path:path}"',
        'frontend_routes["admin"]',
    ]:
        assert fragment in admin_html + admin_js + backend


def test_web13_each_admin_module_loads_only_its_own_data():
    admin_js = read(FRONTEND / "features" / "admin.js")
    orders = read(FRONTEND / "features" / "adminOrders.js")

    products_block = admin_js.split("function renderProductsList", 1)[1].split("function renderProductForm", 1)[0]
    overview_block = admin_js.split("function renderOverview", 1)[1].split("function renderProductsList", 1)[0]

    assert "initAdminProductsList({ profile })" in products_block
    assert "initAdminOrders" not in products_block
    assert "initAdminPayments" not in products_block
    assert "loadMasterProfiles" not in products_block
    assert "loadPartnerApplications" not in products_block
    assert "initAdminProductsList" not in overview_block
    assert "initAdminOrders" not in overview_block

    assert "const orders = await loadAdminOrders()" in orders
    assert "loadAdminPayments()" not in orders.split("async function refresh()", 1)[1].split("async function onConfirmDelivery", 1)[0]
    assert "export async function initAdminPayments()" in orders


def test_web13_product_form_is_wide_and_role_aware_for_partner():
    admin_js = read(FRONTEND / "features" / "admin.js")
    products = read(FRONTEND / "features" / "adminProducts.js")
    css = read(FRONTEND / "css" / "style.css")
    migration = read(MIGRATION)

    for fragment in [
        "admin-product-editor-layout",
        "admin-form-section",
        "Informações principais",
        "Comercial",
        "Descrição",
        "Variações e estoque",
        "Fotos",
        "Preview",
        "Parceiro responsável",
        "Repasse ao parceiro",
        "variationField(\"Tamanho/Variação\", name)",
        "variationField(\"Estoque\", stock)",
        "renderSelfPartnerOption(form, profile)",
        "payoutInput.disabled = true",
        "option.disabled = option.value === \"publicado\"",
        "v_parceiro_user_id := auth.uid();",
        "v_valor_repasse_parceiro := null;",
        "v_status := 'rascunho'::public.shopping_status_produto;",
        "Parceiro so pode editar produtos sob sua responsabilidade.",
    ]:
        assert fragment in admin_js + products + css + migration

    assert "grid-template-columns: minmax(0, 1fr) minmax(280px, 360px)" in css
    assert "min-height: 220px" in css
    assert "grid-template-columns: minmax(0, 1fr) 86px 72px" in css
    assert ".variation-editor__field span" in css


def test_web13_master_only_modules_and_mock_removed_from_admin_ui():
    admin_html = read(FRONTEND / "admin" / "index.html")
    admin_js = read(FRONTEND / "features" / "admin.js")
    orders = read(FRONTEND / "features" / "adminOrders.js")

    for fragment in [
        "roles: [\"master\"]",
        "data-partner-applications",
        "Solicitações de parceiros",
        "Aprovar",
        "Recusar",
        "data-admin-profiles",
        "data-admin-payments-area",
        "Pagamentos reais",
        'payment.provedor !== "mock"',
        "Provider histórico",
    ]:
        assert fragment in admin_html + admin_js + orders

    ui = admin_html + admin_js + orders
    assert "Engine Mock" not in ui
    assert "pagamento simulado" not in ui.lower()
    assert "e-mail simulado" not in ui.lower()
