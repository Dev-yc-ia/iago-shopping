export function setProductImage(
  container,
  {
    src = "",
    alt = "",
    fallbackText = "Foto do produto",
    variant = "catalog",
  } = {},
) {
  container.className = [
    "product-image",
    `product-image--${variant}`,
    src ? "has-image" : "is-empty",
  ].join(" ");

  if (!src) {
    const fallback = document.createElement("span");
    fallback.className = "product-image__fallback";
    fallback.textContent = fallbackText;
    container.replaceChildren(fallback);
    return container;
  }

  const image = document.createElement("img");
  image.className = "product-image__media";
  image.src = src;
  image.alt = alt;
  image.loading = variant === "catalog" ? "lazy" : "eager";
  image.decoding = variant === "catalog" ? "async" : "sync";
  container.replaceChildren(image);
  return container;
}

export function createProductImage(options) {
  return setProductImage(document.createElement("div"), options);
}
