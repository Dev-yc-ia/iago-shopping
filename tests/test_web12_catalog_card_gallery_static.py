from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web12_catalog_uses_real_product_images_without_click_queries():
    products = read(FRONTEND / "config" / "products.js")
    product_card = read(FRONTEND / "ui" / "productCard.js")
    catalog = read(FRONTEND / "features" / "catalog.js")
    product_detail = read(FRONTEND / "features" / "product.js")
    migration = read(ROOT / "sql" / "migrations" / "20260909_015_web07_sku_variacoes_estoque.sql")

    for fragment in [
        "from public.shopping_produto_imagens spi",
        "order by spi.ordem, spi.id",
        "const images = Array.isArray(product.imagens) ? product.imagens : []",
        "images,",
        "imageUrl: firstImageUrl(images)",
        "product.images.filter((image) => image?.url)",
        "Boolean(left.principal) !== Boolean(right.principal)",
        "Number(left.ordem || 0) - Number(right.ordem || 0)",
    ]:
        assert fragment in products + product_card + migration

    assert "getCatalogProducts" in catalog
    assert "productImages(product)" in product_detail + product_card
    assert ".from(\"shopping_produto_imagens\")" not in product_card
    assert "supabase.rpc" not in product_card


def test_web12_product_card_gallery_state_events_and_accessibility():
    product_card = read(FRONTEND / "ui" / "productCard.js")
    product_image = read(FRONTEND / "ui" / "productImage.js")

    for fragment in [
        "function createProductCardMedia(product, categoryLabel)",
        "let imageIndex = 0",
        "if (images.length > 1)",
        "createGalleryButton(\"Foto anterior\", \"prev\", () => goToImage(imageIndex - 1))",
        "createGalleryButton(\"Próxima foto\", \"next\", () => goToImage(imageIndex + 1))",
        "button.type = \"button\"",
        "button.setAttribute(\"aria-label\", label)",
        "document.createElementNS(\"http://www.w3.org/2000/svg\", \"svg\")",
        "icon.setAttribute(\"class\", \"product-card-gallery-button__icon\")",
        "icon.setAttribute(\"viewBox\", \"0 0 24 24\")",
        "path.setAttribute(\"stroke-linecap\", \"round\")",
        "path.setAttribute(\"stroke-linejoin\", \"round\")",
        "event.preventDefault()",
        "event.stopPropagation()",
        "imageIndex = (nextIndex + images.length) % images.length",
        "counter.setAttribute(\"aria-live\", \"polite\")",
        "counter.textContent = images.length > 1 ? `${imageIndex + 1}/${images.length}` : \"\"",
        "preloadImage(images[(imageIndex + 1) % images.length]?.url)",
        "card.append(media, body)",
    ]:
        assert fragment in product_card

    assert 'image.loading = variant === "catalog" ? "lazy" : "eager"' in product_image
    assert 'image.decoding = variant === "catalog" ? "async" : "sync"' in product_image
    assert "icon.className" not in product_card


def test_web12_css_places_gallery_controls_over_catalog_media_on_desktop_and_mobile():
    css = read(FRONTEND / "css" / "style.css")

    for fragment in [
        ".product-card-media",
        "position: relative",
        ".product-card-gallery-button",
        "position: absolute",
        "top: calc(50% + 6px)",
        "width: 34px",
        "height: 34px",
        "display: flex",
        "align-items: center",
        "justify-content: center",
        ".product-card-gallery-button__icon",
        "width: 18px",
        "height: 18px",
        "pointer-events: none",
        "border: 1px solid rgba(25, 221, 218, 0.56)",
        "background: rgba(3, 13, 20, 0.78)",
        "touch-action: manipulation",
        ".product-card-gallery-button--prev",
        "left: 18px",
        ".product-card-gallery-button--next",
        "right: 18px",
        ".product-card-gallery-counter",
        "@media (max-width: 820px)",
        "width: 30px",
        "height: 30px",
        "right: 16px",
        "left: 16px",
    ]:
        assert fragment in css


def test_web12_preserves_catalog_filters_variations_and_sold_out_cta():
    catalog = read(FRONTEND / "features" / "catalog.js")
    product_card = read(FRONTEND / "ui" / "productCard.js")
    css = read(FRONTEND / "css" / "style.css")

    for fragment in [
        "filterProducts",
        "sortProducts",
        "paginateProducts",
        "persistCatalogState(filtered.map((product) => product.id))",
        "grid.replaceChildren(...pagination.items.map((product) => (",
        "availableVariations.slice(0, 6)",
        "catalog-variation-option",
        "availability.textContent = `${variation.stock} un.`",
        "product.availability === \"esgotado\" ? \"Estou interessado\" : \"Ver produto\"",
    ]:
        assert fragment in catalog + product_card

    assert ".product-card:hover .product-variation-chips" not in css
