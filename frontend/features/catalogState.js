export const CATALOG_CONTEXT_STORAGE_KEY = "iago-shopping-catalog-context";
export const CATALOG_CONTEXT_VERSION = 3;

export const DEFAULT_CATALOG_CATEGORY = "todos";

function safeSessionStorage() {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

function positivePage(value) {
  const page = Number(value);
  return Number.isFinite(page) && page > 0 ? Math.floor(page) : 1;
}

export function normalizeCatalogCategory(category) {
  return String(category || DEFAULT_CATALOG_CATEGORY);
}

export function serializeCatalogContext({
  category = DEFAULT_CATALOG_CATEGORY,
  page = 1,
  productIds = [],
} = {}) {
  const normalizedCategory = normalizeCatalogCategory(category);

  return {
    version: CATALOG_CONTEXT_VERSION,
    source: "catalogo",
    category: normalizedCategory,
    filters: {
      category: normalizedCategory,
    },
    page: positivePage(page),
    productIds: productIds.map((id) => String(id || "")).filter(Boolean),
    savedAt: Date.now(),
  };
}

export function saveCatalogContext(context) {
  const storage = safeSessionStorage();
  if (!storage) return;

  try {
    storage.setItem(CATALOG_CONTEXT_STORAGE_KEY, JSON.stringify(context));
  } catch {
    // Preservar navegação mesmo quando o navegador bloquear storage.
  }
}

export function readCatalogContext() {
  const storage = safeSessionStorage();
  if (!storage) return null;

  try {
    const context = JSON.parse(storage.getItem(CATALOG_CONTEXT_STORAGE_KEY) || "null");
    if (context?.version !== CATALOG_CONTEXT_VERSION || context.source !== "catalogo") return null;
    const category = normalizeCatalogCategory(context.category || context.filters?.category);

    return {
      ...context,
      category,
      filters: {
        category,
      },
      page: positivePage(context.page),
      productIds: Array.isArray(context.productIds)
        ? context.productIds.map((id) => String(id || "")).filter(Boolean)
        : [],
    };
  } catch {
    return null;
  }
}

export function resolveAdjacentProductIds(productIds, currentProductId) {
  const ids = Array.isArray(productIds)
    ? productIds.map((id) => String(id || "")).filter(Boolean)
    : [];
  const currentId = String(currentProductId || "");
  const index = ids.indexOf(currentId);

  if (index < 0) {
    return {
      index: -1,
      total: ids.length,
      previousId: "",
      nextId: "",
    };
  }

  return {
    index,
    total: ids.length,
    previousId: ids[index - 1] || "",
    nextId: ids[index + 1] || "",
  };
}
