export const CATALOG_CONTEXT_STORAGE_KEY = "iago-shopping-catalog-context";
export const CATALOG_CONTEXT_VERSION = 2;

export const DEFAULT_CATALOG_FILTERS = {
  search: "",
  category: "todos",
  availability: "todos",
  brand: "todos",
  sort: "relevancia",
};

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

export function normalizeCatalogFilters(filters = {}) {
  return {
    search: String(filters.search || ""),
    category: String(filters.category || DEFAULT_CATALOG_FILTERS.category),
    availability: String(filters.availability || DEFAULT_CATALOG_FILTERS.availability),
    brand: String(filters.brand || DEFAULT_CATALOG_FILTERS.brand),
    sort: String(filters.sort || DEFAULT_CATALOG_FILTERS.sort),
  };
}

export function serializeCatalogContext({
  filters = DEFAULT_CATALOG_FILTERS,
  page = 1,
  filterCollapsed = false,
  productIds = [],
} = {}) {
  return {
    version: CATALOG_CONTEXT_VERSION,
    source: "catalogo",
    filters: normalizeCatalogFilters(filters),
    page: positivePage(page),
    filterCollapsed: Boolean(filterCollapsed),
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
    return {
      ...context,
      filters: normalizeCatalogFilters(context.filters),
      page: positivePage(context.page),
      filterCollapsed: Boolean(context.filterCollapsed),
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
