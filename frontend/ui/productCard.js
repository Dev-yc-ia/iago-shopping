import { formatCurrency } from "../utils/format.js";
import { createProductImage } from "./productImage.js";

export function createProductCard(product, categoryLabel) {
  const status = product.availability === "disponivel" ? "Disponível" : "Esgotado";
  const disabledClass = product.availability === "esgotado" ? " is-muted" : "";

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
  availability.textContent = product.stock > 0 ? `${product.stock} un.` : status;

  const detailLink = document.createElement("a");
  detailLink.className = "card-link";
  detailLink.href = `./produto.html?id=${encodeURIComponent(product.id)}`;
  detailLink.textContent = "Ver produto";

  meta.append(price, availability);
  body.append(brand, title, highlight, meta, detailLink);
  card.append(visual, body);

  return card;
}
