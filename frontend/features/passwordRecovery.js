import {
  recoverPasswordSession,
  resetPasswordForEmail,
  updatePassword,
} from "./auth.js";

const GENERIC_RECOVERY_MESSAGE =
  "Se o e-mail estiver cadastrado, você receberá um link para redefinir sua senha.";

function setMessage(element, message) {
  if (element) {
    element.textContent = message;
  }
}

function validatePassword(password, confirmation) {
  if (password.length < 8) {
    return "A nova senha deve ter pelo menos 8 caracteres.";
  }

  if (!/[A-Z]/.test(password) || !/[a-z]/.test(password) || !/[0-9]/.test(password)) {
    return "Use letras maiúsculas, minúsculas e números na nova senha.";
  }

  if (password !== confirmation) {
    return "A confirmação precisa ser igual à nova senha.";
  }

  return "";
}

function hasRecoveryTokenInUrl() {
  const params = new URLSearchParams(window.location.search);
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  return params.has("code") || hash.has("access_token") || hash.has("refresh_token");
}

export function initPasswordRecoveryPage() {
  const form = document.querySelector("#password-recovery-form");
  const message = document.querySelector("#password-recovery-message");
  if (!form) return;

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const submitButton = form.querySelector("button[type='submit']");
    submitButton.disabled = true;

    try {
      await resetPasswordForEmail(form.elements.email.value);
      setMessage(message, GENERIC_RECOVERY_MESSAGE);
    } catch {
      setMessage(message, GENERIC_RECOVERY_MESSAGE);
    } finally {
      submitButton.disabled = false;
    }
  });
}

export async function initPasswordUpdatePage() {
  const form = document.querySelector("#password-update-form");
  const message = document.querySelector("#password-update-message");
  if (!form) return;

  if (!hasRecoveryTokenInUrl()) {
    setMessage(message, "Link inválido ou expirado. Solicite uma nova recuperação de senha.");
    form.querySelector("button[type='submit']").disabled = true;
    return;
  }

  try {
    const session = await recoverPasswordSession();
    if (!session) {
      throw new Error("Sessão de recuperação ausente.");
    }
  } catch {
    setMessage(message, "Link inválido ou expirado. Solicite uma nova recuperação de senha.");
    form.querySelector("button[type='submit']").disabled = true;
    return;
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const password = form.elements.password.value;
    const confirmation = form.elements.confirmPassword.value;
    const validationMessage = validatePassword(password, confirmation);

    if (validationMessage) {
      setMessage(message, validationMessage);
      return;
    }

    const submitButton = form.querySelector("button[type='submit']");
    submitButton.disabled = true;

    try {
      await updatePassword(password);
      setMessage(message, "Senha alterada com sucesso. Redirecionando para o login.");
      window.setTimeout(() => {
        window.location.href = "/login/";
      }, 1800);
    } catch {
      setMessage(message, "Não foi possível alterar a senha. Solicite um novo link e tente novamente.");
      submitButton.disabled = false;
    }
  });
}
