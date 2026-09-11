import { formatCurrency } from "../utils/format.js";
import { createProductImage, setProductImage } from "./productImage.js";

function productImages(product) {
  const images = Array.isArray(product.images)
    ? product.images.filter((image) => image?.url)
    : [];

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

function preloadImage(url) {
  if (!url) return;
  const image = new Image();
  image.src = url;
}

function renderCatalogImage(container, product, categoryLabel, image, index) {
  setProductImage(container, {
    src: image?.url || "",
    alt: image?.texto_alternativo || `${product.name} - foto ${index + 1}`,
    fallbackText: categoryLabel,
    variant: "catalog",
  });
}

function createGalleryButton(label, direction, onClick) {
  const button = document.createElement("button");
  button.className = `product-card-gallery-button product-card-gallery-button--${direction}`;
  button.type = "button";
  button.setAttribute("aria-label", label);

  const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  icon.setAttribute("class", "product-card-gallery-button__icon");
  icon.setAttribute("aria-hidden", "true");
  icon.setAttribute("focusable", "false");
  icon.setAttribute("viewBox", "0 0 24 24");

  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", direction === "prev" ? "M15 18l-6-6 6-6" : "M9 18l6-6-6-6");
  path.setAttribute("fill", "none");
  path.setAttribute("stroke", "currentColor");
  path.setAttribute("stroke-linecap", "round");
  path.setAttribute("stroke-linejoin", "round");
  path.setAttribute("stroke-width", "3");
  icon.append(path);
  button.append(icon);

  button.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    onClick();
  });
  return button;
}

function createProductCardMedia(product, categoryLabel) {
  const images = productImages(product);
  let imageIndex = 0;

  const media = document.createElement("div");
  media.className = "product-card-media";

  const visual = createProductImage({
    src: "",
    alt: product.name,
    fallbackText: categoryLabel,
    variant: "catalog",
  });

  const counter = document.createElement("span");
  counter.className = "product-card-gallery-counter";
  counter.setAttribute("aria-live", "polite");

  function renderImage() {
    const activeImage = images[imageIndex];
    renderCatalogImage(visual, product, categoryLabel, activeImage, imageIndex);
    counter.textContent = images.length > 1 ? `${imageIndex + 1}/${images.length}` : "";
    preloadImage(images[(imageIndex + 1) % images.length]?.url);
  }

  function goToImage(nextIndex) {
    if (!images.length) return;
    imageIndex = (nextIndex + images.length) % images.length;
    renderImage();
  }

  media.append(visual);
  if (images.length > 1) {
    media.append(
      createGalleryButton("Foto anterior", "prev", () => goToImage(imageIndex - 1)),
      createGalleryButton("Próxima foto", "next", () => goToImage(imageIndex + 1)),
      counter,
    );
  }

  renderImage();
  return media;
}

export function createProductCard(product, categoryLabel) {
  const status = product.availability === "disponivel" ? "Disponível" : "Esgotado";
  const disabledClass = product.availability === "esgotado" ? " is-muted" : "";
  const totalStockLabel = product.stock > 0 ? `${product.stock} un.` : status;

  const card = document.createElement("article");
  card.className = `product-card${disabledClass}`;
  const media = createProductCardMedia(product, categoryLabel);

  const body = document.createElement("div");
  body.className = "product-body";

  const brand = document.createElement("span");
  brand.className = "card-kicker";
  brand.textContent = product.brand;

  const title = document.createElement("h3");
  title.textContent = product.name;

  const highlight = document.createElement("p");
  highlight.textContent = product.highlight;

  const meta = document.createElement("div");
  meta.className = "product-meta";

  const price = document.createElement("strong");
  price.textContent = formatCurrency(product.price);

  const availability = document.createElement("span");
  availability.textContent = totalStockLabel;

  const detailLink = document.createElement("a");
  detailLink.className = "card-link";
  detailLink.href = `/produto/?id=${encodeURIComponent(product.id)}`;
  detailLink.textContent = product.availability === "esgotado" ? "Estou interessado" : "Ver produto";

  const variationList = document.createElement("div");
  variationList.className = "product-variation-chips";
  const availableVariations = product.availableVariations || [];
  if (availableVariations.length > 1 || availableVariations.some((variation) => variation.name !== "Padrao")) {
    variationList.replaceChildren(...availableVariations.slice(0, 6).map((variation) => {
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = "catalog-variation-option";
      chip.textContent = variation.name;
      chip.setAttribute("aria-label", `${variation.name}: ${variation.stock} unidade${variation.stock === 1 ? "" : "s"} em estoque`);
      chip.addEventListener("click", () => {
        variationList.querySelectorAll(".catalog-variation-option").forEach((item) => {
          item.classList.toggle("is-selected", item === chip);
          item.setAttribute("aria-pressed", String(item === chip));
        });
        availability.textContent = `${variation.stock} un.`;
      });
      return chip;
    }));
  }

  meta.append(price, availability);
  body.append(brand, title, highlight, meta, variationList, detailLink);
  card.append(media, body);

  return card;
}
