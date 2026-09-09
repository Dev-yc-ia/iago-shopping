import { CATALOG_SOURCE, CATEGORIES, getCatalogProducts } from "../config/products.js";
import { createProductCard } from "../ui/productCard.js";
import { normalizeText } from "../utils/format.js";
import {
  readCatalogContext,
  saveCatalogContext,
  serializeCatalogContext,
} from "./catalogState.js";

const PAGE_SIZE = 8;
const DEFAULT_FILTERS_COLLAPSED = true;
const MOBILE_CATALOG_MEDIA = "(max-width: 820px)";

function categoryLabel(categoryId) {
  return CATEGORIES.find((category) => category.id === categoryId)?.label || categoryId;
}

function visibleCategoriesFromProducts(products) {
  const categoryIds = new Set(products.map((product) => product.category).filter(Boolean));
  return CATEGORIES.filter((category) => category.id === "todos" || categoryIds.has(category.id));
}

function buildOptions(select, categories) {
  select.replaceChildren(...categories.map((category) => {
    const option = document.createElement("option");
    option.value = category.id;
    option.textContent = category.label;
    return option;
  }));
}

function buildBrandOptions(select, products) {
  const brands = ["todos", ...new Set(products.map((product) => product.brand).sort())];
  select.replaceChildren(...brands.map((brand) => {
    const option = document.createElement("option");
    option.value = brand;
    option.textContent = brand === "todos" ? "Todas" : brand;
    return option;
  }));
}

function buildTabs(container, categories, onSelect) {
  container.replaceChildren(...categories.map((category) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "category-tab";
    button.dataset.category = category.id;
    button.textContent = category.label;
    return button;
  }));

  container.addEventListener("click", (event) => {
    const button = event.target.closest("[data-category]");
    if (!button) return;
    onSelect(button.dataset.category);
  });
}

function filterProducts(products, { search, category, availability, brand }) {
  const term = normalizeText(search);

  return products.filter((product) => {
    const matchesCategory = category === "todos" || product.category === category;
    const matchesAvailability = availability === "todos" || product.availability === availability;
    const matchesBrand = brand === "todos" || product.brand === brand;
    const searchable = normalizeText([
      product.name,
      product.brand,
      product.highlight,
      product.description,
      ...product.attributes.map((item) => `${item.label} ${item.value}`),
    ].join(" "));

    return matchesCategory && matchesAvailability && matchesBrand && searchable.includes(term);
  });
}

function availabilityWeight(product) {
  return product.availability === "esgotado" ? 1 : 0;
}

function compareProductsBySortMode(left, right, sortMode) {
  if (sortMode === "menor-preco") {
    return left.product.price - right.product.price;
  }
  if (sortMode === "maior-preco") {
    return right.product.price - left.product.price;
  }
  if (sortMode === "nome") {
    return left.product.name.localeCompare(right.product.name, "pt-BR");
  }
  return 0;
}

function sortProducts(products, sortMode) {
  return products
    .map((product, index) => ({ product, index }))
    .sort((left, right) => (
      availabilityWeight(left.product) - availabilityWeight(right.product)
      || compareProductsBySortMode(left, right, sortMode)
      || left.index - right.index
    ))
    .map((item) => item.product);
}

function paginateProducts(products, page) {
  const totalPages = Math.max(1, Math.ceil(products.length / PAGE_SIZE));
  const currentPage = Math.min(Math.max(page, 1), totalPages);
  const start = (currentPage - 1) * PAGE_SIZE;
  return {
    currentPage,
    totalPages,
    items: products.slice(start, start + PAGE_SIZE),
  };
}

export async function initCatalogPage() {
  const catalogLayout = document.querySelector(".catalog-layout");
  const filterPanel = document.querySelector(".filters-panel");
  const filterToggle = document.querySelector("#toggle-filters");
  const grid = document.querySelector("#product-grid");
  const empty = document.querySelector("#empty-state");
  const search = document.querySelector("#search-products");
  const category = document.querySelector("#category-filter");
  const availability = document.querySelector("#availability-filter");
  const brand = document.querySelector("#brand-filter");
  const sort = document.querySelector("#sort-products");
  const tabs = document.querySelector("#category-tabs");
  const count = document.querySelector("#catalog-count");
  const source = document.querySelector("#catalog-source");
  const pageStatus = document.querySelector("#page-status");
  const previousPage = document.querySelector("#previous-page");
  const nextPage = document.querySelector("#next-page");

  if (!grid || !category || !availability || !brand || !sort || !search || !tabs) return;

  const mobileCatalog = window.matchMedia(MOBILE_CATALOG_MEDIA);
  let currentPage = 1;
  let filtersCollapsed = DEFAULT_FILTERS_COLLAPSED;
  const savedContext = readCatalogContext();
  const products = await getCatalogProducts();
  const visibleCategories = visibleCategoriesFromProducts(products);

  buildOptions(category, visibleCategories);
  buildBrandOptions(brand, products);

  function currentFilters() {
    return {
      search: search.value,
      category: category.value,
      availability: availability.value,
      brand: brand.value,
      sort: sort.value,
    };
  }

  function setExistingSelectValue(select, value, fallback = "todos") {
    const hasOption = Array.from(select.options).some((option) => option.value === value);
    select.value = hasOption ? value : fallback;
  }

  function applyFilterPanelState() {
    catalogLayout?.classList.toggle("filters-collapsed", filtersCollapsed);
    filterPanel?.classList.toggle("is-collapsed", filtersCollapsed);

    if (filterToggle) {
      filterToggle.textContent = filtersCollapsed ? ">>>" : "<<<";
      filterToggle.setAttribute(
        "aria-label",
        filtersCollapsed ? "Expandir filtros do catálogo" : "Recolher filtros do catálogo"
      );
      filterToggle.setAttribute("aria-expanded", String(!filtersCollapsed));
    }
  }

  function restoreCatalogState() {
    if (!savedContext) {
      applyFilterPanelState();
      return;
    }

    const filters = savedContext.filters;
    search.value = filters.search;
    setExistingSelectValue(category, filters.category);
    setExistingSelectValue(availability, filters.availability);
    setExistingSelectValue(brand, filters.brand);
    setExistingSelectValue(sort, filters.sort, "relevancia");
    currentPage = savedContext.page;
    filtersCollapsed = savedContext.filterCollapsed;
    applyFilterPanelState();
  }

  function persistCatalogState(productIds) {
    saveCatalogContext(serializeCatalogContext({
      filters: currentFilters(),
      page: currentPage,
      filterCollapsed: filtersCollapsed,
      productIds,
    }));
  }

  function shouldUseFullPageGrid(itemsLength) {
    if (itemsLength <= 0) return false;
    if (!filtersCollapsed) return itemsLength === PAGE_SIZE;
    return !mobileCatalog.matches;
  }

  buildTabs(tabs, visibleCategories, (categoryId) => {
    category.value = categoryId;
    currentPage = 1;
    render();
    document.querySelector("#catalogo")?.scrollIntoView({ behavior: "smooth", block: "start" });
  });

  function syncTabs() {
    tabs.querySelectorAll(".category-tab").forEach((button) => {
      button.classList.toggle("active", button.dataset.category === category.value);
    });
  }

  function render() {
    const filtered = sortProducts(filterProducts(products, {
      search: search.value,
      category: category.value,
      availability: availability.value,
      brand: brand.value,
    }), sort.value);

    const pagination = paginateProducts(filtered, currentPage);
    currentPage = pagination.currentPage;
    grid.classList.toggle("is-full-page", shouldUseFullPageGrid(pagination.items.length));
    persistCatalogState(filtered.map((product) => product.id));

    grid.replaceChildren(...pagination.items.map((product) => (
      createProductCard(product, categoryLabel(product.category))
    )));

    empty.classList.toggle("hidden", filtered.length > 0);
    if (count) {
      count.textContent = `${filtered.length} produto${filtered.length === 1 ? "" : "s"} encontrado${filtered.length === 1 ? "" : "s"}`;
    }
    if (source) {
      source.textContent = CATALOG_SOURCE === "mock"
        ? "Fonte mock preparada para Supabase"
        : "Fonte Supabase";
    }
    if (pageStatus) {
      pageStatus.textContent = `Página ${pagination.currentPage} de ${pagination.totalPages}`;
    }
    if (previousPage) {
      previousPage.disabled = pagination.currentPage <= 1;
    }
    if (nextPage) {
      nextPage.disabled = pagination.currentPage >= pagination.totalPages;
    }
    syncTabs();
  }

  [search, category, availability, brand, sort].forEach((element) => {
    element.addEventListener("input", () => {
      currentPage = 1;
      render();
    });
    element.addEventListener("change", () => {
      currentPage = 1;
      render();
    });
  });

  previousPage?.addEventListener("click", () => {
    currentPage -= 1;
    render();
  });

  nextPage?.addEventListener("click", () => {
    currentPage += 1;
    render();
  });

  filterToggle?.addEventListener("click", () => {
    filtersCollapsed = !filtersCollapsed;
    applyFilterPanelState();
    render();
  });

  restoreCatalogState();
  render();
}
