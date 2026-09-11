from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web14_orders_moves_from_header_to_user_menu():
    auth = read(FRONTEND / "features" / "auth.js")
    user_menu = read(FRONTEND / "ui" / "userMenu.js")

    assert 'appendAuthenticatedLink(nav, "/pedidos/", "Pedidos"' not in auth
    assert 'ordersLink.href = "/pedidos/"' in user_menu
    assert 'ordersLink.textContent = "Pedidos"' in user_menu

    profile_index = user_menu.index('profileLink.textContent = "Dados pessoais"')
    orders_index = user_menu.index('ordersLink.textContent = "Pedidos"')
    logout_index = user_menu.index('logoutButton.textContent = "Sair"')
    append_index = user_menu.index("dropdown.append(profileLink, ordersLink, logoutButton)")

    assert profile_index < orders_index < logout_index < append_index


def test_web14_header_cart_uses_inline_svg_with_real_badge_source():
    auth = read(FRONTEND / "features" / "auth.js")
    cart = read(FRONTEND / "features" / "cart.js")
    css = read(FRONTEND / "css" / "style.css")

    for fragment in [
        "function appendHeaderCartLink(nav)",
        'link.href = "/carrinho/"',
        'link.setAttribute("aria-label", "Carrinho")',
        'svg.setAttribute("fill", "none")',
        'svg.setAttribute("stroke", "currentColor")',
        "header-cart-link",
        "header-cart-icon",
        "header-cart-badge",
        "data-cart-badge",
        "export async function updateHeaderCartBadge()",
        'supabase.rpc("shopping_carrinho_atual")',
        "Number(item.quantidade || 0)",
        "badge.hidden = quantity <= 0",
        'badge.textContent = quantity > 0 ? String(quantity) : ""',
    ]:
        assert fragment in auth + cart + css

    assert 'appendAuthenticatedLink(nav, "/carrinho/", "Carrinho"' not in auth


def test_web14_cart_badge_refreshes_without_rebuilding_header():
    auth = read(FRONTEND / "features" / "auth.js")
    cart = read(FRONTEND / "features" / "cart.js")

    for fragment in [
        'const HEADER_CART_REFRESH_EVENT = "iago:cart:updated"',
        "window.addEventListener(HEADER_CART_REFRESH_EVENT, cartBadgeRefreshHandler)",
        "window.removeEventListener(HEADER_CART_REFRESH_EVENT, cartBadgeRefreshHandler)",
        "updateHeaderCartBadge();",
        'const CART_UPDATED_EVENT = "iago:cart:updated"',
        "function notifyCartChanged()",
        "notifyCartChanged();",
    ]:
        assert fragment in auth + cart

    unchanged_header_branch = auth.split("if (signature === lastAuthNavigationSignature)", 1)[1].split("resetDynamicNavigation(nav)", 1)[0]
    assert "updateHeaderCartBadge();" in unchanged_header_branch
    assert "resetDynamicNavigation(nav)" not in unchanged_header_branch


def test_web14_admin_roles_remain_authorized_in_header():
    auth = read(FRONTEND / "features" / "auth.js")

    assert '["master", "funcionario", "parceiro"].includes(profile.papel)' in auth
    assert "adminLink.hidden = !canAccessAdmin(profile)" in auth
