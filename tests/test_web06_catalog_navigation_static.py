from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web06_catalog_context_module_preserves_filters_and_sequence():
    state = read(FRONTEND / "features" / "catalogState.js")

    for fragment in [
        'CATALOG_CONTEXT_STORAGE_KEY = "iago-shopping-catalog-context"',
        "CATALOG_CONTEXT_VERSION = 2",
        'source: "catalogo"',
        "normalizeCatalogFilters",
        "serializeCatalogContext",
        "saveCatalogContext",
        "readCatalogContext",
        "resolveAdjacentProductIds",
        "filterCollapsed",
        "productIds",
    ]:
        assert fragment in state


def test_web06_catalog_restores_state_and_collapses_filters_without_clearing_values():
    html = read(FRONTEND / "catalogo" / "index.html")
    catalog = read(FRONTEND / "features" / "catalog.js")
    css = read(FRONTEND / "css" / "style.css")

    for fragment in [
        'id="toggle-filters"',
        'aria-controls="filters-panel-body"',
        'id="filters-panel-body"',
        "readCatalogContext",
        "DEFAULT_FILTERS_COLLAPSED = true",
        'MOBILE_CATALOG_MEDIA = "(max-width: 820px)"',
        "saveCatalogContext",
        "serializeCatalogContext",
        "persistCatalogState(filtered.map((product) => product.id))",
        "shouldUseFullPageGrid(pagination.items.length)",
        "return !mobileCatalog.matches",
        "filtersCollapsed = savedContext.filterCollapsed",
        'filterToggle.textContent = filtersCollapsed ? ">>>" : "<<<"',
        ".catalog-layout.filters-collapsed",
        ".filters-panel.is-collapsed .filters-panel-body",
        ".catalog-layout.filters-collapsed .product-grid.is-full-page",
        "grid-template-columns: repeat(4, minmax(0, 1fr))",
        "height: clamp(190px, 16vw, 220px)",
    ]:
        assert fragment in html + catalog + css


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
