import { getSupabaseClient } from "./auth.js";
import { createProductImage, setProductImage } from "../ui/productImage.js";

const EMPTY_PRODUCT = {
  id: null,
  sku: "",
  nome: "",
  marca: "",
  categoria: "shapes",
  preco: "",
  quantidade_estoque: 0,
  descricao: "",
  status: "rascunho",
  imagens: [],
};

const CATEGORY_LABELS = {
  shapes: "Shapes",
  rodas: "Rodas",
  tenis: "Tênis",
  "roupas-camisas": "Roupas e camisas",
  "cameras-acessorios": "Câmeras e acessórios",
};

const PRODUCT_PHOTOS_BUCKET = "shopping-produtos";
const MAX_PHOTO_SIZE_BYTES = 5 * 1024 * 1024;
const ALLOWED_PHOTO_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
]);

let selectedPhotoPreviewUrls = [];
let selectedCoverIndex = 0;
let currentPersistedImages = [];

function formatCurrency(value) {
  const number = Number(value || 0);
  return new Intl.NumberFormat("pt-BR", {
    style: "currency",
    currency: "BRL",
  }).format(number);
}

function parseStock(value) {
  const stock = Number.parseInt(value, 10);
  return Number.isFinite(stock) && stock > 0 ? stock : 0;
}

function stockLabel(stock) {
  const quantity = parseStock(stock);
  return `${quantity} unidade${quantity === 1 ? "" : "s"}`;
}

function firstImageUrl(images = []) {
  const primary = images.find((image) => image.principal);
  return primary?.url || images[0]?.url || "";
}

function coverIndexForImages(images = []) {
  const index = images.findIndex((image) => image.principal);
  return index >= 0 ? index : 0;
}

function normalizeImagesWithCover(images = [], coverIndex = selectedCoverIndex) {
  return images.map((image, index) => ({
    ...image,
    ordem: index,
    principal: index === coverIndex,
  }));
}

function revokeSelectedPhotoPreview() {
  selectedPhotoPreviewUrls.forEach((url) => URL.revokeObjectURL(url));
  selectedPhotoPreviewUrls = [];
}

function renderImagePreview(container, images = [], onCoverSelect = null) {
  if (!container) return;
  container.className = "product-photo-gallery-preview";

  const imageList = images.filter((image) => image.url);
  if (!imageList.length) {
    const empty = document.createElement("div");
    setProductImage(empty, {
      fallbackText: "Nenhuma foto selecionada",
      variant: "form-preview",
    });
    container.replaceChildren(empty);
    return;
  }

  container.replaceChildren(...imageList.map((image, index) => {
    const item = document.createElement("figure");
    item.className = "product-photo-gallery-preview__item";
    item.classList.toggle("is-cover", image.principal);

    const preview = createProductImage({
      src: image.url,
      alt: image.texto_alternativo || `Foto ${index + 1} do produto`,
      fallbackText: "Foto do produto",
      variant: "form-preview",
    });

    const caption = document.createElement("figcaption");
    caption.textContent = image.principal ? "Capa" : `Foto ${index + 1}`;

    const coverButton = document.createElement("button");
    coverButton.className = "button ghost product-cover-button";
    coverButton.type = "button";
    coverButton.disabled = image.principal;
    coverButton.textContent = image.principal ? "Capa selecionada" : "Usar como capa";
    coverButton.addEventListener("click", () => onCoverSelect?.(index));

    item.append(preview, caption, coverButton);
    return item;
  }));
}

function renderVisualPreview(container, imageUrl) {
  if (!container) return;
  setProductImage(container, {
    src: imageUrl,
    alt: "Prévia do card do produto",
    fallbackText: "Foto Principal",
    variant: "live-preview",
  });
}

function selectedPreviewImages() {
  return normalizeImagesWithCover(selectedPhotoPreviewUrls.map((url, index) => ({
    url,
    texto_alternativo: index === selectedCoverIndex ? "Foto de capa selecionada" : `Foto selecionada ${index + 1}`,
    ordem: index,
    principal: index === selectedCoverIndex,
  })));
}

function currentPreviewImages() {
  return selectedPhotoPreviewUrls.length
    ? selectedPreviewImages()
    : normalizeImagesWithCover(currentPersistedImages);
}

function refreshPhotoPreview(form) {
  const images = currentPreviewImages();
  renderImagePreview(document.querySelector("[data-product-image-preview]"), images, (index) => {
    selectedCoverIndex = index;
    refreshPhotoPreview(form);
  });
  updateLivePreview(form, firstImageUrl(images));
}

function setSelectedPhotos(files, form) {
  revokeSelectedPhotoPreview();
  selectedCoverIndex = 0;
  selectedPhotoPreviewUrls = files.map((file) => URL.createObjectURL(file));

  refreshPhotoPreview(form);
}

function getSelectedPhotos(form) {
  return Array.from(form.elements.fotosProduto?.files || []);
}

function clearSelectedPhotos(form) {
  revokeSelectedPhotoPreview();
  if (form.elements.fotosProduto) form.elements.fotosProduto.value = "";
}

function safeStorageSegment(value) {
  return String(value || "produto")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80) || "produto";
}

function fileExtension(file) {
  const byType = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
    "image/gif": "gif",
  };
  if (byType[file.type]) return byType[file.type];

  const nameExtension = file.name?.split(".").pop()?.toLowerCase();
  return nameExtension || "jpg";
}

function validateProductPhoto(file) {
  if (!file) return;

  if (!ALLOWED_PHOTO_TYPES.has(file.type)) {
    throw new Error("Use uma imagem em JPG, PNG, WEBP ou GIF.");
  }

  if (file.size > MAX_PHOTO_SIZE_BYTES) {
    throw new Error("Cada foto do produto deve ter no máximo 5 MB.");
  }
}

async function uploadProductPhotoToStorage(supabase, file, product, index) {
  validateProductPhoto(file);

  const sku = safeStorageSegment(product.sku);
  const uniqueName = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const path = `produtos/${sku}/${uniqueName}.${fileExtension(file)}`;
  const { error } = await supabase.storage
    .from(PRODUCT_PHOTOS_BUCKET)
    .upload(path, file, {
      cacheControl: "3600",
      contentType: file.type,
      upsert: false,
    });

  if (error) {
    throw new Error(`Não foi possível salvar a foto ${index + 1}: ${error.message}`);
  }

  const { data } = supabase.storage.from(PRODUCT_PHOTOS_BUCKET).getPublicUrl(path);
  if (!data?.publicUrl) {
    throw new Error("A foto foi enviada, mas a URL pública não foi retornada pelo Supabase.");
  }

  return {
    url: data.publicUrl,
    texto_alternativo: product.nome || product.sku || `Foto ${index + 1} do produto`,
    ordem: index,
    principal: index === selectedCoverIndex,
    caminho_storage: path,
  };
}

async function uploadProductPhotosToStorage(supabase, files, product) {
  if (!files.length) return [];

  const uploadedImages = [];
  for (const [index, file] of files.entries()) {
    try {
      const uploadedImage = await uploadProductPhotoToStorage(supabase, file, product, index);
      uploadedImages.push(uploadedImage);
    } catch (error) {
      await removeUploadedPhotosOnFailure(supabase, uploadedImages);
      throw error;
    }
  }

  return uploadedImages;
}

async function removeUploadedPhotosOnFailure(supabase, images) {
  const paths = images
    .map((image) => image.caminho_storage)
    .filter(Boolean);
  if (!paths.length) return;

  await supabase.storage
    .from(PRODUCT_PHOTOS_BUCKET)
    .remove(paths);
}

async function listProducts() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_admin_listar_produtos_com_estoque");
  if (error) throw error;
  return data || [];
}

async function saveProduct(product) {
  const supabase = await getSupabaseClient();
  const uploadedImages = await uploadProductPhotosToStorage(supabase, product.fotosProduto, product);
  const imagens = uploadedImages.length ? uploadedImages : product.imagens;

  try {
    const { error } = await supabase.rpc("shopping_admin_salvar_produto_com_estoque", {
      p_id: product.id,
      p_sku: product.sku,
      p_nome: product.nome,
      p_marca: product.marca,
      p_categoria: product.categoria,
      p_preco: Number(product.preco),
      p_destaque: null,
      p_descricao: product.descricao || null,
      p_atributos: [],
      p_imagens: imagens,
      p_status: product.status,
      p_quantidade_estoque: parseStock(product.quantidadeEstoque),
    });
    if (error) throw error;
  } catch (error) {
    await removeUploadedPhotosOnFailure(supabase, uploadedImages);
    throw error;
  }
}

async function deleteProduct(productId) {
  const supabase = await getSupabaseClient();
  const { error } = await supabase.rpc("shopping_admin_excluir_produto", {
    p_id: productId,
    p_motivo: "Exclusao administrativa pela Fase 5 do IAGO Shopping.",
  });
  if (error) throw error;
}

function getFormValue(form, name) {
  return form.elements[name]?.value || "";
}

function readProductForm(form) {
  return {
    id: getFormValue(form, "id") || null,
    sku: getFormValue(form, "sku"),
    nome: getFormValue(form, "nome"),
    marca: getFormValue(form, "marca"),
    categoria: getFormValue(form, "categoria"),
    preco: getFormValue(form, "preco"),
    quantidadeEstoque: getFormValue(form, "quantidadeEstoque"),
    descricao: getFormValue(form, "descricao"),
    status: getFormValue(form, "status"),
    fotosProduto: getSelectedPhotos(form),
    imagens: normalizeImagesWithCover(currentPersistedImages),
  };
}

function fillProductForm(form, product = EMPTY_PRODUCT) {
  currentPersistedImages = product.imagens || [];
  selectedCoverIndex = coverIndexForImages(currentPersistedImages);
  clearSelectedPhotos(form);

  form.elements.id.value = product.id || "";
  form.elements.sku.value = product.sku || "";
  form.elements.nome.value = product.nome || "";
  form.elements.marca.value = product.marca || "";
  form.elements.categoria.value = product.categoria || "shapes";
  form.elements.preco.value = product.preco ?? "";
  form.elements.quantidadeEstoque.value = product.quantidade_estoque ?? 0;
  form.elements.descricao.value = product.descricao || "";
  form.elements.status.value = product.status || "rascunho";

  refreshPhotoPreview(form);
}

function productTitle(product) {
  return product.nome || product.sku || "Produto sem nome";
}

function updateLivePreview(form, imageUrl = firstImageUrl(currentPreviewImages())) {
  const card = document.querySelector("[data-product-live-preview]");
  if (!card) return;

  const status = getFormValue(form, "status") || "rascunho";
  const stock = parseStock(getFormValue(form, "quantidadeEstoque"));
  card.classList.toggle("is-muted", status === "arquivado" || stock === 0);

  renderVisualPreview(card.querySelector("[data-preview-visual]"), imageUrl);

  const previewName = card.querySelector("[data-preview-name]");
  const previewDescription = card.querySelector("[data-preview-description]");
  const previewBrand = card.querySelector("[data-preview-brand]");
  const previewPrice = card.querySelector("[data-preview-price]");
  const previewStatus = card.querySelector("[data-preview-status]");
  const previewCategory = card.querySelector("[data-preview-category]");
  const previewAvailability = card.querySelector("[data-preview-availability]");
  const previewStock = card.querySelector("[data-preview-stock]");
  const category = getFormValue(form, "categoria");

  if (previewName) previewName.textContent = getFormValue(form, "nome") || "Nome do produto";
  if (previewDescription) {
    previewDescription.textContent = getFormValue(form, "descricao") || CATEGORY_LABELS[category] || "Descrição comercial";
  }
  if (previewBrand) previewBrand.textContent = getFormValue(form, "marca") || "Marca";
  if (previewPrice) previewPrice.textContent = formatCurrency(getFormValue(form, "preco"));
  if (previewStatus) previewStatus.textContent = status;
  if (previewCategory) previewCategory.textContent = CATEGORY_LABELS[category] || "Categoria";
  if (previewAvailability) previewAvailability.textContent = stock > 0 ? "Disponível" : "Esgotado";
  if (previewStock) previewStock.textContent = stockLabel(stock);
}

function renderProductCard(product, onEdit, onDelete) {
  const card = document.createElement("article");
  card.className = "admin-card";

  const status = document.createElement("span");
  status.className = "card-kicker";
  status.textContent = product.status;

  const title = document.createElement("h2");
  title.textContent = productTitle(product);

  const description = document.createElement("p");
  description.textContent = `${product.sku} | ${product.marca} | ${product.categoria} | ${stockLabel(product.quantidade_estoque)}`;

  const imageUrl = firstImageUrl(product.imagens);
  const image = createProductImage({
    src: imageUrl,
    alt: productTitle(product),
    fallbackText: "Foto Principal",
    variant: "admin-thumb",
  });
  card.append(image);

  const editButton = document.createElement("button");
  editButton.className = "button secondary";
  editButton.type = "button";
  editButton.textContent = "Editar";
  editButton.addEventListener("click", () => onEdit(product));

  const deleteButton = document.createElement("button");
  deleteButton.className = "button ghost";
  deleteButton.type = "button";
  deleteButton.textContent = "Excluir";
  deleteButton.addEventListener("click", () => onDelete(product.id));

  card.append(status, title, description, editButton, deleteButton);
  return card;
}

export function initAdminProducts() {
  const form = document.querySelector("[data-product-form]");
  const list = document.querySelector("[data-products-list]");
  const feedback = document.querySelector("[data-product-feedback]");

  if (!form || !list) return;

  async function refreshProducts() {
    try {
      const products = await listProducts();
      list.replaceChildren(
        ...products.map((product) => renderProductCard(product, fillProductForm.bind(null, form), async (id) => {
          try {
            await deleteProduct(id);
            fillProductForm(form);
            await refreshProducts();
          } catch (error) {
            if (feedback) feedback.textContent = error.message;
          }
        })),
      );
      if (feedback) {
        feedback.textContent = `${products.length} produto${products.length === 1 ? "" : "s"} cadastrado${products.length === 1 ? "" : "s"}.`;
      }
    } catch (error) {
      if (feedback) feedback.textContent = error.message;
    }
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const product = readProductForm(form);
    try {
      await saveProduct(product);
      fillProductForm(form);
      await refreshProducts();
    } catch (error) {
      if (feedback) feedback.textContent = error.message;
    }
  });

  form.addEventListener("input", () => updateLivePreview(form));
  form.addEventListener("change", () => updateLivePreview(form));
  form.elements.fotosProduto?.addEventListener("change", () => {
    setSelectedPhotos(getSelectedPhotos(form), form);
  });

  form.querySelector("[data-product-reset]")?.addEventListener("click", () => {
    fillProductForm(form);
  });

  fillProductForm(form);
  refreshProducts();
}
