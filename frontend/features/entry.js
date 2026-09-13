import { recordEvent } from "../utils/analytics.js";
import { recoverSessionProfile, signInWithGoogle, signInWithPassword, signUpCliente } from "./auth.js";

let authMode = "login";

function safeRedirectTarget() {
  const target = new URLSearchParams(window.location.search).get("redirect");
  if (!target || !target.startsWith("/") || target.startsWith("//") || /^[a-z][a-z0-9+.-]*:/i.test(target)) {
    return "/catalogo/";
  }
  return target;
}

function showLoginNotice() {
  const notice = document.querySelector("[data-login-notice]");
  if (!notice) return;

  const reason = new URLSearchParams(window.location.search).get("aviso");
  const messages = {
    carrinho: "Para comprar e montar seu carrinho, entre ou crie sua conta no IAGO Shopping.",
    pedidos: "Para finalizar e acompanhar seus pedidos, entre ou crie sua conta no IAGO Shopping.",
    interesse: "Para registrar interesse em um produto esgotado, entre ou crie sua conta no IAGO Shopping.",
  };
  if (!messages[reason]) return;

  notice.hidden = false;
  notice.textContent = messages[reason];
}

function setAuthMode(mode) {
  authMode = mode;
  document.body.dataset.authMode = mode;

  const submitLabel = document.querySelector("#home-access-form .entry-primary-submit .entry-button-label");
  if (submitLabel) submitLabel.textContent = mode === "signup" ? "Criar conta" : "Entrar no Shopping";

  document.querySelectorAll("[data-login-actions]").forEach((element) => {
    element.toggleAttribute("hidden", mode === "signup");
  });
  document.querySelectorAll("[data-signup-actions]").forEach((element) => {
    element.toggleAttribute("hidden", mode !== "signup");
  });
}

function currentModeFromLocation() {
  return window.location.hash === "#create-account" ? "signup" : "login";
}

export function initEntryPage() {
  showLoginNotice();
  setAuthMode(currentModeFromLocation());

  recoverSessionProfile()
    .then(({ session }) => {
      if (session?.user) window.location.href = safeRedirectTarget();
    })
    .catch((error) => console.warn(error.message));

  window.addEventListener("hashchange", () => {
    setAuthMode(currentModeFromLocation());
  });

  document.querySelector("#home-access-form")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    recordEvent("login_start", { source: authMode === "signup" ? "entry_signup_form" : "entry_form" });
    const access = document.querySelector("#home-access")?.value;
    const password = document.querySelector("#home-password")?.value;

    try {
      if (authMode === "signup") {
        await signUpCliente(access, password);
        window.alert("Conta criada. Se o Supabase exigir confirmação, confirme o e-mail antes de entrar.");
      } else {
        await signInWithPassword(access, password);
      }
      window.location.href = safeRedirectTarget();
    } catch (error) {
      window.alert(error.message);
    }
  });

  document.querySelector(".entry-password-toggle")?.addEventListener("click", (event) => {
    const button = event.currentTarget;
    const passwordInput = document.querySelector("#home-password");
    if (!passwordInput) return;

    const shouldShowPassword = passwordInput.type === "password";
    passwordInput.type = shouldShowPassword ? "text" : "password";
    button.setAttribute("aria-pressed", String(shouldShowPassword));
    button.setAttribute("aria-label", shouldShowPassword ? "Ocultar senha" : "Mostrar senha");
    passwordInput.focus();
  });

  document.querySelector("#continue-with-google")?.addEventListener("click", async (event) => {
    const button = event.currentTarget;
    const label = button.querySelector(".entry-button-label");
    const originalLabel = label?.textContent ?? button.textContent;
    button.disabled = true;
    if (label) {
      label.textContent = "Abrindo Google...";
    } else {
      button.textContent = "Abrindo Google...";
    }
    recordEvent("login_start", { source: authMode === "signup" ? "google_visual_signup" : "google_visual_entry" });
    try {
      await signInWithGoogle(`${window.location.pathname}${window.location.search}`);
    } catch (error) {
      button.disabled = false;
      if (label) {
        label.textContent = originalLabel;
      } else {
        button.textContent = originalLabel;
      }
      window.alert(error.message);
    }
  });

  document.querySelector("#continue-without-login")?.addEventListener("click", () => {
    recordEvent("continue_without_login", { source: "entry_page" });
  });

  document.querySelector("[data-login-toggle]")?.addEventListener("click", (event) => {
    event.preventDefault();
    setAuthMode("login");
    history.pushState(null, "", `${window.location.pathname}${window.location.search}`);
  });
}
