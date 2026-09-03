import { recordEvent } from "../utils/analytics.js";
import { signInWithGoogle, signInWithPassword, signUpCliente } from "./auth.js";

let authMode = "login";

function safeRedirectTarget() {
  const target = new URLSearchParams(window.location.search).get("redirect");
  if (!target || !target.startsWith("./") || target.includes("//")) {
    return "./catalogo.html";
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

  document.querySelector("#google-login-button")?.addEventListener("click", async () => {
    recordEvent("login_start", { source: "google_visual_login" });
    try {
      await signInWithGoogle();
    } catch (error) {
      window.alert(error.message);
    }
  });

  document.querySelector("[data-signup-toggle]")?.addEventListener("click", (event) => {
    event.preventDefault();
    setAuthMode("signup");
  });
}
