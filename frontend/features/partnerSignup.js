import { SELLER_TERMS, SELLER_TERMS_ACCEPTANCE_TEXT } from "../config/sellerTerms.js";
import {
  getCurrentSession,
  recoverSessionProfile,
  signInWithGoogle,
  signInWithPassword,
  signUpParceiro,
  submitPartnerApplication,
} from "./auth.js";
import { recordEvent } from "../utils/analytics.js";

function digitsOnly(value) {
  return String(value || "").replace(/\D+/g, "");
}

function setFeedback(message, tone = "") {
  const feedback = document.querySelector("[data-partner-feedback]");
  if (!feedback) return;

  feedback.hidden = !message;
  feedback.textContent = message || "";
  feedback.dataset.tone = tone;
}

function setSessionStatus(session, profile) {
  const status = document.querySelector("[data-partner-session-status]");
  if (!status) return;

  if (!session?.user) {
    status.textContent = "Entre ou crie sua conta para enviar a solicitação.";
    return;
  }

  const displayName = profile?.nome_completo || profile?.nome_exibicao || session.user.email;
  status.textContent = `Conta conectada: ${displayName}.`;
}

function setAuthButtonsEnabled(enabled) {
  document.querySelectorAll("[data-partner-password-login], [data-partner-password-signup], [data-partner-google]")
    .forEach((button) => {
      button.disabled = !enabled;
    });
}

function fillTerms() {
  const read = document.querySelector("[data-seller-terms-read]");
  const download = document.querySelector("[data-seller-terms-download]");
  const version = document.querySelector("[data-seller-terms-version]");
  const effective = document.querySelector("[data-seller-terms-effective]");
  const text = document.querySelector("[data-seller-terms-text]");

  if (read) read.href = SELLER_TERMS.pdfUrl;
  if (download) download.href = SELLER_TERMS.pdfUrl;
  if (version) version.textContent = SELLER_TERMS.version;
  if (effective) effective.textContent = SELLER_TERMS.effectiveDateLabel;
  if (text) text.textContent = SELLER_TERMS_ACCEPTANCE_TEXT;
}

function prefillFromSession(form, session, profile) {
  if (!form || !session?.user) return;

  if (form.elements.email && !form.elements.email.value) {
    form.elements.email.value = session.user.email || "";
  }
  if (form.elements.nome && !form.elements.nome.value) {
    form.elements.nome.value = profile?.nome_completo || profile?.nome_exibicao || "";
  }
  if (form.elements.telefone && !form.elements.telefone.value) {
    form.elements.telefone.value = profile?.telefone_normalizado || "";
  }
}

function readApplication(form) {
  const tipoPessoa = form.elements.tipoPessoa?.value || "PF";
  const documento = digitsOnly(form.elements.documento?.value);
  const nome = String(form.elements.nome?.value || "").trim();
  const nomeLoja = String(form.elements.nomeLoja?.value || "").trim();
  const telefone = digitsOnly(form.elements.telefone?.value);
  const aceite = Boolean(form.elements.aceiteTermos?.checked);

  if (!["PF", "PJ"].includes(tipoPessoa)) {
    throw new Error("Selecione Pessoa Física ou Pessoa Jurídica.");
  }

  if (!nome) {
    throw new Error("Informe o nome ou razão social.");
  }

  if (tipoPessoa === "PF" && documento.length !== 11) {
    throw new Error("Informe um CPF com 11 números.");
  }

  if (tipoPessoa === "PJ" && documento.length !== 14) {
    throw new Error("Informe um CNPJ com 14 números.");
  }

  if (!aceite) {
    throw new Error("Para enviar a solicitação, aceite os Termos e Condições para Vendedores.");
  }

  return {
    tipoPessoa,
    documento,
    nome,
    nomeLoja,
    telefone,
    aceite,
    userAgent: navigator.userAgent || "",
  };
}

async function refreshSession(form) {
  const authState = await recoverSessionProfile();
  setSessionStatus(authState.session, authState.profile);
  prefillFromSession(form, authState.session, authState.profile);
  return authState;
}

async function requireSession() {
  const session = await getCurrentSession();
  if (!session?.user) {
    throw new Error("Entre com e-mail/senha ou Google antes de enviar a solicitação.");
  }
  return session;
}

export function initPartnerSignupPage() {
  const form = document.querySelector("[data-partner-form]");
  if (!form) return;

  fillTerms();
  refreshSession(form).catch((error) => setFeedback(error.message, "error"));

  form.querySelector("[data-partner-password-login]")?.addEventListener("click", async () => {
    setFeedback("");
    setAuthButtonsEnabled(false);
    try {
      await signInWithPassword(form.elements.email?.value, form.elements.password?.value);
      await refreshSession(form);
      setFeedback("Conta conectada. Complete os dados e aceite os termos para enviar.", "success");
    } catch (error) {
      setFeedback(error.message, "error");
    } finally {
      setAuthButtonsEnabled(true);
    }
  });

  form.querySelector("[data-partner-password-signup]")?.addEventListener("click", async () => {
    setFeedback("");
    setAuthButtonsEnabled(false);
    try {
      await signUpParceiro(form.elements.email?.value, form.elements.password?.value);
      await refreshSession(form);
      setFeedback("Conta criada. Se o Supabase exigir confirmação, confirme o e-mail antes de enviar a solicitação.", "success");
    } catch (error) {
      setFeedback(error.message, "error");
    } finally {
      setAuthButtonsEnabled(true);
    }
  });

  form.querySelector("[data-partner-google]")?.addEventListener("click", async () => {
    setFeedback("");
    setAuthButtonsEnabled(false);
    recordEvent("login_start", { source: "partner_signup_google" });
    try {
      await signInWithGoogle("/cadastro-parceiro/");
    } catch (error) {
      setFeedback(error.message, "error");
      setAuthButtonsEnabled(true);
    }
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    setFeedback("");

    try {
      await requireSession();
      await submitPartnerApplication(readApplication(form));
      recordEvent("partner_application_submitted", {
        terms_version: SELLER_TERMS.version,
        terms_id: SELLER_TERMS.id,
      });
      setFeedback("Solicitação enviada. Seu cadastro ficará pendente até a análise do Master.", "success");
      form.querySelector("button[type='submit']").disabled = true;
    } catch (error) {
      setFeedback(error.message, "error");
    }
  });
}
