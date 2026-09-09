from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CSS = ROOT / "frontend" / "css" / "style.css"
CARD = ROOT / "frontend" / "ui" / "productCard.js"


def read(path):
    return path.read_text(encoding="utf-8")


def test_mobile_catalog_card_price_and_stock_stack_without_js_changes():
    css = read(CSS)
    card = read(CARD)

    mobile_media = css[css.index("@media (max-width: 820px)"):]

    for fragment in [
        ".product-grid .product-card .product-meta",
        "flex-direction: column;",
        "align-items: flex-start;",
        "justify-content: flex-start;",
        "gap: 3px;",
        ".product-grid .product-card .product-meta strong",
        ".product-grid .product-card .product-meta span",
        "white-space: nowrap;",
        "grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));",
    ]:
        assert fragment in mobile_media

    assert "status-row {\n    flex-direction: column;" not in mobile_media
    assert 'detailLink.textContent = product.availability === "esgotado" ? "Estou interessado" : "Ver produto";' in card
