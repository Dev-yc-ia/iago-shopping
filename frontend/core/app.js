import { initAdminPage } from "../features/admin.js";
import { initAuthNavigation } from "../features/auth.js";
import { initCartPage } from "../features/cart.js";
import { initCheckoutPage } from "../features/checkout.js";
import { initCatalogPage } from "../features/catalog.js";
import { initEntryPage } from "../features/entry.js";
import { initLoginPage } from "../features/login.js";
import { initOrdersPage } from "../features/orders.js";
import { initPasswordRecoveryPage, initPasswordUpdatePage } from "../features/passwordRecovery.js";
import { initPartnerSignupPage } from "../features/partnerSignup.js";
import { initProductPage } from "../features/product.js";
import { initProfilePage } from "../features/profile.js";
import { recordEvent } from "../utils/analytics.js";

function trackGlobalActions() {
  document.querySelectorAll("[data-track-login]").forEach((element) => {
    element.addEventListener("click", () => {
      recordEvent("login_start", { source: "home_cta" });
    });
  });
}

function boot() {
  const page = document.body.dataset.page;
  recordEvent("entry", { page });
  trackGlobalActions();
  initAuthNavigation();

  if (page === "entry") initEntryPage();
  if (page === "catalog") initCatalogPage();
  if (page === "product") initProductPage();
  if (page === "cart") initCartPage();
  if (page === "checkout") initCheckoutPage();
  if (page === "orders") initOrdersPage();
  if (page === "login") initLoginPage();
  if (page === "partner-signup") initPartnerSignupPage();
  if (page === "admin") initAdminPage();
  if (page === "profile") initProfilePage();
  if (page === "password-recovery") initPasswordRecoveryPage();
  if (page === "password-update") initPasswordUpdatePage();
}

boot();
