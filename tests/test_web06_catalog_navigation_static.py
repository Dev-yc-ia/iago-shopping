from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web06_catalog_context_module_preserves_category_page_and_sequence():
    state = read(FRONTEND / "features" / "catalogState.js")

    for fragment in [
        'CATALOG_CONTEXT_STORAGE_KEY = "iago-shopping-catalog-context"',
        "CATALOG_CONTEXT_VERSION = 3",
        'source: "catalogo"',
        "DEFAULT_CATALOG_CATEGORY",
        "normalizeCatalogCategory",
        "serializeCatalogContext",
        "saveCatalogContext",
        "readCatalogContext",
        "resolveAdjacentProductIds",
        "category",
        "productIds",
    ]:
        assert fragment in state

    for removed_fragment in [
        "filterCollapsed",
        "availability",
        "brand",
        "sort",
    ]:
        assert removed_fragment not in state


def test_web06_catalog_removes_filter_panel_and_restores_category_state():
    html = read(FRONTEND / "catalogo" / "index.html")
    catalog = read(FRONTEND / "features" / "catalog.js")
    css = read(FRONTEND / "css" / "style.css")

    for fragment in [
        "readCatalogContext",
        "saveCatalogContext",
        "serializeCatalogContext",
        "selectedCategory",
        "hasCategory(visibleCategories, savedContext.category)",
        "filterProducts(products, selectedCategory)",
        "persistCatalogState(filtered.map((product) => product.id))",
        "shouldUseFullPageGrid(pagination.items.length)",
        "grid-template-columns: repeat(4, minmax(0, 1fr))",
        "height: clamp(190px, 16vw, 220px)",
        "Nenhum produto encontrado nesta categoria.",
    ]:
        assert fragment in html + catalog + css

    for removed_fragment in [
        'id="toggle-filters"',
        'aria-controls="filters-panel-body"',
        'id="filters-panel-body"',
        'id="search-products"',
        'id="category-filter"',
        'id="availability-filter"',
        'id="brand-filter"',
        'id="sort-products"',
        "DEFAULT_FILTERS_COLLAPSED",
        "MOBILE_CATALOG_MEDIA",
        "filtersCollapsed",
        ".catalog-layout.filters-collapsed",
        ".filters-panel.is-collapsed",
        "normalizeText",
    ]:
        assert removed_fragment not in html + catalog + css


def test_web06_product_navigation_uses_catalog_sequence_and_keeps_direct_url_safe():
    html = read(FRONTEND / "produto" / "index.html")
    product = read(FRONTEND / "features" / "product.js")

    for fragment in [
        'id="product-sequence-nav"',
        "readCatalogContext",
        "resolveAdjacentProductIds",
        "savedIds.includes(currentProductId) ? savedIds : defaultIds",
        "Produto anterior",
        "Próximo produto",
        "`/produto/?id=${encodeURIComponent(productId)}`",
        "renderProductNavigation(resolveProductSequence(products, product.id))",
    ]:
        assert fragment in html + product


def test_web06_auth_navigation_uses_cached_signature_to_avoid_redundant_header_render():
    auth = read(FRONTEND / "features" / "auth.js")

    for fragment in [
        'AUTH_NAVIGATION_CACHE_KEY = "iago-shopping-auth-navigation-state"',
        "lastAuthNavigationSignature",
        "authNavigationSignature",
        "readAuthNavigationCache",
        "writeAuthNavigationCache",
        "canReuseCachedAvatarUrl",
        "resolveAuthNavigationState(undefined, cachedState)",
        "resolveAuthNavigationState(session, readAuthNavigationCache())",
        "invalidateAuthNavigationCache",
        "renderAuthNavigationState",
        "if (signature === lastAuthNavigationSignature)",
        "supabase.auth.onAuthStateChange",
        'if (event === "INITIAL_SESSION") return',
        "clearAuthNavigationCache()",
    ]:
        assert fragment in auth


def test_web06_profile_photo_update_refreshes_avatar_cache_only_when_photo_changes():
    profile = read(FRONTEND / "features" / "profile.js")
    menu = read(FRONTEND / "ui" / "userMenu.js")

    for fragment in [
        "invalidateAuthNavigationCache",
        "initAuthNavigation",
        "oldAvatarPath !== currentAvatarPath",
        'image.loading = "eager"',
        'image.decoding = "sync"',
    ]:
        assert fragment in profile + menu
