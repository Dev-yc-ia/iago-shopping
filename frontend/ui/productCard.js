import { formatCurrency } from "../utils/format.js";
import { createProductImage } from "./productImage.js";

export function createProductCard(product, categoryLabel) {
  const status = product.availability === "disponivel" ? "Disponível" : "Esgotado";
  const disabledClass = product.availability === "esgotado" ? " is-muted" : "";
  const totalStockLabel = product.stock > 0 ? `${product.stock} un.` : status;

  const card = document.createElement("article");
  card.className = `product-card${disabledClass}`;

  const visual = createProductImage({
    src: product.imageUrl,
    alt: product.name,
    fallbackText: categoryLabel,
    variant: "catalog",
  });

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
  card.append(visual, body);

  return card;
}
