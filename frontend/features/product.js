import { CATEGORIES, getCatalogProducts } from "../config/products.js";
import { recordEvent } from "../utils/analytics.js";
import { formatCurrency } from "../utils/format.js";
import { createProductImage, setProductImage } from "../ui/productImage.js";
import { getSupabaseClient } from "./auth.js";
import { addProductToCart } from "./cart.js";
import { readCatalogContext, resolveAdjacentProductIds } from "./catalogState.js";

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

function productDetailUrl(productId) {
  return `/produto/?id=${encodeURIComponent(productId)}`;
}

function createProductNavigationControl(productId, label, direction) {
  if (!productId) {
    const button = document.createElement("button");
    button.className = "button secondary";
    button.type = "button";
    button.disabled = true;
    button.textContent = label;
    return button;
  }

  const link = document.createElement("a");
  link.className = "button secondary";
  link.href = productDetailUrl(productId);
  link.rel = direction;
  link.textContent = label;
  return link;
}

function resolveProductSequence(products, currentProductId) {
  const savedContext = readCatalogContext();
  const savedIds = savedContext?.productIds || [];
  const defaultIds = products.map((product) => product.id);
  const sequenceIds = savedIds.includes(currentProductId) ? savedIds : defaultIds;

  return resolveAdjacentProductIds(sequenceIds, currentProductId);
}

function renderProductNavigation(sequence) {
  const container = document.querySelector("#product-sequence-nav");
  if (!container) return;

  const previous = createProductNavigationControl(sequence.previousId, "Produto anterior", "prev");
  const next = createProductNavigationControl(sequence.nextId, "Próximo produto", "next");
  container.replaceChildren(previous, next);
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

function shouldShowVariationSelector(product) {
  const variations = product.availableVariations || [];
  return variations.length > 1 || variations.some((variation) => variation.name !== "Padrao");
}

function renderVariationSelector(product, onSelect) {
  const variations = product.availableVariations || [];
  if (!shouldShowVariationSelector(product)) return null;

  const group = document.createElement("div");
  group.className = "product-variation-selector";

  const label = document.createElement("span");
  label.className = "card-kicker";
  label.textContent = "Tamanho";

  const options = document.createElement("div");
  options.className = "product-variation-options";

  options.replaceChildren(...variations.map((variation) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "variation-option";
    button.textContent = variation.name;
    button.dataset.variationId = variation.id;
    button.addEventListener("click", () => {
      options.querySelectorAll(".variation-option").forEach((item) => {
        item.classList.toggle("is-selected", item === button);
      });
      onSelect(variation);
    });
    return button;
  }));

  group.append(label, options);
  return group;
}

function currentRelativeProductUrl() {
  return `/produto/${window.location.search}`;
}

function redirectToInterestLogin(productId) {
  recordEvent("product_interest_login_required", { productId });
  const redirect = encodeURIComponent(currentRelativeProductUrl());
  window.location.href = `/login/?aviso=interesse&redirect=${redirect}`;
}

async function getAuthenticatedInterestClient(productId) {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;

  if (!data.session?.user) {
    redirectToInterestLogin(productId);
    return null;
  }

  return supabase;
}

async function loadProductInterestStatus(productId) {
  const supabase = await getSupabaseClient();
  const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
  if (sessionError) throw sessionError;
  if (!sessionData.session?.user) return false;

  const { data, error } = await supabase.rpc("shopping_produto_interesse_status", {
    p_produto_id: productId,
  });
  if (error) throw error;

  const status = Array.isArray(data) ? data[0] : data;
  return Boolean(status?.registrado);
}

async function registerProductInterest(productId) {
  const supabase = await getAuthenticatedInterestClient(productId);
  if (!supabase) return null;

  const { data, error } = await supabase.rpc("shopping_produto_interesse_registrar", {
    p_produto_id: productId,
  });
  if (error) throw error;

  const result = Array.isArray(data) ? data[0] : data;
  recordEvent("product_interest_register", {
    productId,
    created: Boolean(result?.criado),
  });
  return result;
}

function setInterestRegistered(button, feedback, message) {
  button.disabled = true;
  button.textContent = "Interesse registrado";
  feedback.dataset.tone = "success";
  feedback.textContent = message || "Interesse registrado! A IAGO vai considerar essa demanda nas próximas encomendas.";
}

function createSoldOutInterestPanel(product) {
  const panel = document.createElement("div");
  panel.className = "product-interest-panel";

  const title = document.createElement("strong");
  title.textContent = "Quer esse produto?";

  const message = document.createElement("p");
  message.textContent = "Registre seu interesse para a IAGO avaliar uma nova encomenda.";

  const button = document.createElement("button");
  button.className = "button primary product-interest-button";
  button.type = "button";
  button.textContent = "Registrar interesse";

  const feedback = document.createElement("p");
  feedback.className = "product-interest-feedback";
  feedback.setAttribute("role", "status");

  button.addEventListener("click", async () => {
    const originalLabel = button.textContent;
    button.disabled = true;
    button.textContent = "Registrando...";
    feedback.textContent = "";

    try {
      const result = await registerProductInterest(product.id);
      if (!result) return;

      setInterestRegistered(button, feedback, result.mensagem);
    } catch (error) {
      button.disabled = false;
      button.textContent = originalLabel;
      feedback.dataset.tone = "error";
      feedback.textContent = error.message;
    }
  });

  loadProductInterestStatus(product.id)
    .then((registered) => {
      if (registered) {
        setInterestRegistered(button, feedback, "Seu interesse neste produto já está registrado.");
      }
    })
    .catch((error) => console.warn(error.message));

  panel.append(title, message, button, feedback);
  return panel;
}

function renderProductDetail(container, product) {
  const status = product.availability === "disponivel" ? "Disponível" : "Esgotado";
  const isSoldOut = product.availability === "esgotado";
  const availableVariations = product.availableVariations || [];
  const needsVariationSelection = shouldShowVariationSelector(product);
  let selectedVariation = needsVariationSelection ? null : availableVariations[0] || null;

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
  description.className = "product-description";
  description.textContent = product.description;

  const price = document.createElement("div");
  price.className = "product-price";
  price.textContent = formatCurrency(product.price);

  const statusRow = document.createElement("div");
  statusRow.className = "status-row";

  const availability = document.createElement("span");
  availability.textContent = status;

  const stock = document.createElement("span");
  stock.textContent = selectedVariation
    ? `${selectedVariation.stock} unidades`
    : `${product.stock} unidades`;

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
  extensionNote.textContent = "Estoque real contabilizado por variação.";

  const cartButton = document.createElement("button");
  cartButton.className = "button primary product-cart-button";
  cartButton.type = "button";
  cartButton.disabled = product.availability !== "disponivel" || needsVariationSelection;
  cartButton.textContent = product.availability !== "disponivel"
    ? "Produto esgotado"
    : needsVariationSelection
      ? "Selecione um tamanho"
      : "Adicionar ao carrinho";
  cartButton.addEventListener("click", async () => {
    try {
      if (needsVariationSelection && !selectedVariation) {
        window.alert("Selecione um tamanho antes de adicionar ao carrinho.");
        return;
      }
      const added = await addProductToCart(product.id, 1, selectedVariation?.id || null);
      if (added) window.location.href = "/carrinho/";
    } catch (error) {
      window.alert(error.message);
    }
  });

  const variationSelector = renderVariationSelector(product, (variation) => {
    selectedVariation = variation;
    stock.textContent = `${variation.stock} unidades`;
    cartButton.disabled = false;
    cartButton.textContent = "Adicionar ao carrinho";
  });

  statusRow.append(availability, stock);
  info.append(brand, title, description, price, statusRow);
  if (!isSoldOut && variationSelector) info.append(variationSelector);
  if (isSoldOut) {
    info.append(createSoldOutInterestPanel(product), attributes);
  } else {
    info.append(cartButton, attributes, extensionNote);
  }
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
  renderProductNavigation(resolveProductSequence(products, product.id));
  renderProductDetail(container, product);
}
