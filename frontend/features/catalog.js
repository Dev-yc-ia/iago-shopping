import { CATALOG_SOURCE, CATEGORIES, getCatalogProducts } from "../config/products.js";
import { createProductCard } from "../ui/productCard.js";
import {
  readCatalogContext,
  saveCatalogContext,
  serializeCatalogContext,
} from "./catalogState.js";

const PAGE_SIZE = 8;
const DEFAULT_CATEGORY = "todos";

function categoryLabel(categoryId) {
  return CATEGORIES.find((category) => category.id === categoryId)?.label || categoryId;
}

function visibleCategoriesFromProducts(products) {
  const categoryIds = new Set(products.map((product) => product.category).filter(Boolean));
  return CATEGORIES.filter((category) => category.id === "todos" || categoryIds.has(category.id));
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

function hasCategory(categories, categoryId) {
  return categories.some((category) => category.id === categoryId);
}

function filterProducts(products, category) {
  return products.filter((product) => category === DEFAULT_CATEGORY || product.category === category);
}

function availabilityWeight(product) {
  return product.availability === "esgotado" ? 1 : 0;
}

function sortProducts(products) {
  return products
    .map((product, index) => ({ product, index }))
    .sort((left, right) => (
      availabilityWeight(left.product) - availabilityWeight(right.product)
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
  const grid = document.querySelector("#product-grid");
  const empty = document.querySelector("#empty-state");
  const tabs = document.querySelector("#category-tabs");
  const count = document.querySelector("#catalog-count");
  const source = document.querySelector("#catalog-source");
  const pageStatus = document.querySelector("#page-status");
  const previousPage = document.querySelector("#previous-page");
  const nextPage = document.querySelector("#next-page");

  if (!grid || !tabs) return;

  let currentPage = 1;
  let selectedCategory = DEFAULT_CATEGORY;
  const savedContext = readCatalogContext();
  const products = await getCatalogProducts();
  const visibleCategories = visibleCategoriesFromProducts(products);

  function restoreCatalogState() {
    if (savedContext) {
      selectedCategory = hasCategory(visibleCategories, savedContext.category)
        ? savedContext.category
        : DEFAULT_CATEGORY;
      currentPage = savedContext.page;
    }
  }

  function persistCatalogState(productIds) {
    saveCatalogContext(serializeCatalogContext({
      category: selectedCategory,
      page: currentPage,
      productIds,
    }));
  }

  function shouldUseFullPageGrid(itemsLength) {
    return itemsLength >= 4;
  }

  buildTabs(tabs, visibleCategories, (categoryId) => {
    selectedCategory = hasCategory(visibleCategories, categoryId) ? categoryId : DEFAULT_CATEGORY;
    currentPage = 1;
    render();
    document.querySelector("#catalogo")?.scrollIntoView({ behavior: "smooth", block: "start" });
  });

  function syncTabs() {
    tabs.querySelectorAll(".category-tab").forEach((button) => {
      button.classList.toggle("active", button.dataset.category === selectedCategory);
    });
  }

  function render() {
    const filtered = sortProducts(filterProducts(products, selectedCategory));

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

  previousPage?.addEventListener("click", () => {
    currentPage -= 1;
    render();
  });

  nextPage?.addEventListener("click", () => {
    currentPage += 1;
    render();
  });

  restoreCatalogState();
  render();
}
