import { CATEGORIES, getCatalogProducts } from "../config/products.js";
import { recordEvent } from "../utils/analytics.js";
import { formatCurrency } from "../utils/format.js";
import { createProductImage, setProductImage } from "../ui/productImage.js";
import { addProductToCart } from "./cart.js";

function getProductId(products) {
  return new URLSearchParams(window.location.search).get("id") || products[0]?.id || "";
}

function getCategoryLabel(categoryId) {
  return CATEGORIES.find((category) => category.id === categoryId)?.label || categoryId;
}

function productImages(product) {
  const images = Array.isArray(product.images) ? product.images.filter((image) => image.url) : [];
  if (images.length) {
    return [...images].sort((left, right) => {
      if (Boolean(left.principal) !== Boolean(right.principal)) {
        return left.principal ? -1 : 1;
      }
      return Number(left.ordem || 0) - Number(right.ordem || 0);
    });
  }
  if (product.imageUrl) {
    return [{
      url: product.imageUrl,
      texto_alternativo: product.name,
      principal: true,
      ordem: 0,
    }];
  }
  return [];
}

function renderNotFound(container) {
  const panel = document.createElement("div");
  panel.className = "notice-panel";

  const title = document.createElement("h1");
  title.textContent = "Produto não encontrado";

  const message = document.createElement("p");
  message.textContent = "Volte ao catálogo e selecione um produto publicado.";

  panel.append(title, message);
  container.replaceChildren(panel);
}

function renderProductGallery(product) {
  const images = productImages(product);
  let activeIndex = 0;

  const gallery = document.createElement("div");
  gallery.className = "product-gallery";

  const activeFrame = document.createElement("div");
  const controls = document.createElement("div");
  controls.className = "product-gallery-controls";

  const previousButton = document.createElement("button");
  previousButton.className = "button secondary";
  previousButton.type = "button";
  previousButton.textContent = "Anterior";

  const status = document.createElement("span");

  const nextButton = document.createElement("button");
  nextButton.className = "button secondary";
  nextButton.type = "button";
  nextButton.textContent = "Próxima";

  const thumbnails = document.createElement("div");
  thumbnails.className = "product-gallery-thumbnails";

  function renderActiveImage() {
    const activeImage = images[activeIndex];
    setProductGalleryImage(activeFrame, activeImage, product);

    status.textContent = images.length > 1
      ? `Foto ${activeIndex + 1} de ${images.length}`
      : "Foto principal";
    previousButton.disabled = images.length <= 1;
    nextButton.disabled = images.length <= 1;

    thumbnails.querySelectorAll("[data-gallery-index]").forEach((button) => {
      button.classList.toggle("active", Number(button.dataset.galleryIndex) === activeIndex);
    });
  }

  function goToImage(index) {
    activeIndex = (index + images.length) % images.length;
    renderActiveImage();
  }

  previousButton.addEventListener("click", () => goToImage(activeIndex - 1));
  nextButton.addEventListener("click", () => goToImage(activeIndex + 1));

  thumbnails.replaceChildren(...images.map((image, index) => {
    const button = document.createElement("button");
    button.className = "product-gallery-thumb";
    button.type = "button";
    button.dataset.galleryIndex = String(index);
    button.setAttribute("aria-label", `Ver foto ${index + 1}`);
    button.append(createProductImage({
      src: image.url,
      alt: image.texto_alternativo || `${product.name} - foto ${index + 1}`,
      fallbackText: "Foto",
      variant: "gallery-thumb",
    }));
    button.addEventListener("click", () => goToImage(index));
    return button;
  }));

  controls.append(previousButton, status, nextButton);
  gallery.append(activeFrame);
  if (images.length > 1) gallery.append(controls, thumbnails);
  renderActiveImage();
  return gallery;
}

function setProductGalleryImage(container, image, product) {
  setProductImage(container, {
    src: image?.url || "",
    alt: image?.texto_alternativo || product.name,
    fallbackText: getCategoryLabel(product.category),
    variant: "detail",
  });
}

function renderProductDetail(container, product) {
  const status = product.availability === "disponivel" ? "Disponível" : "Esgotado";
  const interestText = product.availability === "esgotado"
    ? "Registrar interesse em esgotados será uma extensão futura."
    : "Estoque real contabilizado por variação.";

  const showcase = document.createElement("div");
  showcase.className = "product-showcase";

  const visual = renderProductGallery(product);

  const info = document.createElement("div");
  info.className = "product-info";

  const brand = document.createElement("span");
  brand.className = "eyebrow";
  brand.textContent = product.brand;

  const title = document.createElement("h1");
  title.textContent = product.name;

  const description = document.createElement("p");
  description.textContent = product.description;

  const price = document.createElement("div");
  price.className = "product-price";
  price.textContent = formatCurrency(product.price);

  const statusRow = document.createElement("div");
  statusRow.className = "status-row";

  const availability = document.createElement("span");
  availability.textContent = status;

  const stock = document.createElement("span");
  stock.textContent = `${product.stock} unidades`;

  const attributes = document.createElement("dl");
  attributes.className = "attributes-list";
  product.attributes.forEach((attribute) => {
    const row = document.createElement("div");
    const term = document.createElement("dt");
    const value = document.createElement("dd");

    term.textContent = attribute.label;
    value.textContent = attribute.value;
    row.append(term, value);
    attributes.append(row);
  });

  const extensionNote = document.createElement("p");
  extensionNote.className = "extension-note";
  extensionNote.textContent = interestText;

  const cartButton = document.createElement("button");
  cartButton.className = "button primary product-cart-button";
  cartButton.type = "button";
  cartButton.disabled = product.availability !== "disponivel";
  cartButton.textContent = product.availability === "disponivel"
    ? "Adicionar ao carrinho"
    : "Produto esgotado";
  cartButton.addEventListener("click", async () => {
    try {
      const added = await addProductToCart(product.id, 1);
      if (added) window.location.href = "/carrinho/";
    } catch (error) {
      window.alert(error.message);
    }
  });

  statusRow.append(availability, stock);
  info.append(brand, title, description, price, statusRow, cartButton, attributes, extensionNote);
  showcase.append(visual, info);
  container.replaceChildren(showcase);
}

export async function initProductPage() {
  const container = document.querySelector("#product-detail");
  if (!container) return;

  const products = await getCatalogProducts();
  const product = products.find((item) => item.id === getProductId(products));
  if (!product) {
    renderNotFound(container);
    return;
  }

  recordEvent("product_view", { productId: product.id, category: product.category });
  renderProductDetail(container, product);
}
