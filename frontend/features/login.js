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
  };
  if (!messages[reason]) return;

  notice.hidden = false;
  notice.textContent = messages[reason];
}

function setAuthMode(mode) {
  authMode = mode;
  const submitButton = document.querySelector("#login-form .button.primary");
  if (submitButton) {
    submitButton.textContent = mode === "signup" ? "Criar conta de cliente" : "Entrar no Shopping";
  }
}

export function initLoginPage() {
  showLoginNotice();

  recoverSessionProfile()
    .then(({ session }) => {
      if (session?.user) window.location.href = safeRedirectTarget();
    })
    .catch((error) => console.warn(error.message));

  if (window.location.hash === "#create-account") {
    setAuthMode("signup");
  }

  document.querySelector("#login-form")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    recordEvent("login_start", { source: "login_page" });
    const access = document.querySelector("#login-access")?.value;
    const password = document.querySelector("#login-password")?.value;

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

  document.querySelector("[data-continue-link]")?.addEventListener("click", () => {
    recordEvent("continue_without_login", { source: "login_page" });
  });

  document.querySelector("#google-login-button")?.addEventListener("click", async (event) => {
    const button = event.currentTarget;
    const originalLabel = button.textContent;
    button.disabled = true;
    button.textContent = "Abrindo Google...";
    recordEvent("login_start", { source: "google_visual_login" });
    try {
      await signInWithGoogle(`${window.location.pathname}${window.location.search}`);
    } catch (error) {
      button.disabled = false;
      button.textContent = originalLabel;
      window.alert(error.message);
    }
  });

  document.querySelector("[data-signup-toggle]")?.addEventListener("click", (event) => {
    event.preventDefault();
    setAuthMode("signup");
  });
}
