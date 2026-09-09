from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"
MIGRATION = ROOT / "sql" / "migrations" / "20260909_016_web08_esgotados_interesse_categorias.sql"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web08_catalog_sorts_sold_out_after_available_before_pagination():
    catalog = read(FRONTEND / "features" / "catalog.js")
    card = read(FRONTEND / "ui" / "productCard.js")

    for fragment in [
        "function availabilityWeight(product)",
        'return product.availability === "esgotado" ? 1 : 0;',
        "function compareProductsBySortMode(left, right, sortMode)",
        'sortMode === "menor-preco"',
        'sortMode === "maior-preco"',
        'sortMode === "nome"',
        "availabilityWeight(left.product) - availabilityWeight(right.product)",
        "|| left.index - right.index",
        "const pagination = paginateProducts(filtered, currentPage);",
        "persistCatalogState(filtered.map((product) => product.id));",
        'product.availability === "esgotado" ? "Estou interessado" : "Ver produto"',
    ]:
        assert fragment in catalog + card


def test_web08_catalog_uses_dynamic_categories_from_loaded_products():
    catalog = read(FRONTEND / "features" / "catalog.js")

    for fragment in [
        "function visibleCategoriesFromProducts(products)",
        "new Set(products.map((product) => product.category).filter(Boolean))",
        'category.id === "todos" || categoryIds.has(category.id)',
        "const visibleCategories = visibleCategoriesFromProducts(products);",
        "buildOptions(category, visibleCategories);",
        "buildTabs(tabs, visibleCategories, (categoryId) => {",
        "setExistingSelectValue(category, filters.category);",
    ]:
        assert fragment in catalog


def test_web08_product_interest_flow_uses_login_redirect_and_rpc():
    product = read(FRONTEND / "features" / "product.js")
    login = read(FRONTEND / "features" / "login.js")

    for fragment in [
        'return `/produto/${window.location.search}`;',
        'window.location.href = `/login/?aviso=interesse&redirect=${redirect}`;',
        "getAuthenticatedInterestClient(productId)",
        "shopping_produto_interesse_status",
        "shopping_produto_interesse_registrar",
        "createSoldOutInterestPanel(product)",
        "Registre seu interesse para a IAGO avaliar uma nova encomenda.",
        "Registrar interesse",
        "Interesse registrado",
        "Interesse registrado! A IAGO vai considerar essa demanda nas próximas encomendas.",
        "Seu interesse neste produto já está registrado.",
        "interesse: \"Para registrar interesse em um produto esgotado",
    ]:
        assert fragment in product + login


def test_web08_sql_persists_interest_with_rls_and_server_side_stock_validation():
    migration = read(MIGRATION)

    for fragment in [
        "create table if not exists public.shopping_produto_interesses",
        "produto_id uuid not null references public.shopping_produtos(id) on delete cascade",
        "user_id uuid not null references auth.users(id) on delete cascade",
        "constraint shopping_produto_interesses_produto_user_unique unique (produto_id, user_id)",
        "alter table public.shopping_produto_interesses enable row level security",
        "user_id = auth.uid()",
        "public.shopping_is_admin(auth.uid())",
        "with check (",
        "and not exists (",
        "and spv.estoque_atual > 0",
        "v_user_id uuid := auth.uid()",
        "sp.status = 'publicado'::public.shopping_status_produto",
        "sum(spv.estoque_atual) filter (where spv.ativo)",
        "Produto disponivel para compra. Interesse so pode ser registrado para produto esgotado.",
        "on conflict on constraint shopping_produto_interesses_produto_user_unique",
        "do nothing",
        "grant execute on function public.shopping_produto_interesse_status(uuid) to authenticated",
        "grant execute on function public.shopping_produto_interesse_registrar(uuid) to authenticated",
        "notify pgrst, 'reload schema'",
    ]:
        assert fragment in migration
