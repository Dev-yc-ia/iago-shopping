import {
  getSupabaseClient,
  googleAvatarUrlFromSession,
  googleDisplayNameFromSession,
  initAuthNavigation,
  invalidateAuthNavigationCache,
} from "./auth.js";
import {
  CHECKOUT_REQUIRED_FIELD_LABELS,
  CHECKOUT_REQUIRED_FIELDS,
  validateCheckoutProfile,
} from "../utils/checkoutProfile.js";

const AVATAR_BUCKET = "shopping-avatars";
const MAX_AVATAR_SIZE_BYTES = 5 * 1024 * 1024;
const ALLOWED_AVATAR_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
]);
const PAYMENT_METHODS = new Set(["pix", "cartao_debito", "cartao_credito"]);

let selectedAvatarFile = null;
let selectedAvatarPreviewUrl = "";
let currentAvatarPath = null;
let pendingAvatarRemoval = false;

function currentRelativeUrl() {
  return `/dados-pessoais/${window.location.search}`;
}

function redirectToLogin() {
  const redirect = encodeURIComponent(currentRelativeUrl());
  window.location.href = `/login/?redirect=${redirect}`;
}

function getFormValue(form, name) {
  return String(form.elements[name]?.value || "").trim();
}

function normalizeOptional(value) {
  const normalized = String(value || "").trim();
  return normalized || null;
}

function fileExtension(file) {
  const byType = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
  };
  if (byType[file.type]) return byType[file.type];
  return file.name?.split(".").pop()?.toLowerCase() || "jpg";
}

function validateAvatar(file) {
  if (!file) return;

  if (!ALLOWED_AVATAR_TYPES.has(file.type)) {
    throw new Error("Use uma imagem em JPG, PNG ou WEBP.");
  }

  if (file.size > MAX_AVATAR_SIZE_BYTES) {
    throw new Error("A foto de perfil deve ter no máximo 5 MB.");
  }
}

function profileInitial(profile, session) {
  const source = profile?.nome_completo
    || profile?.nome_exibicao
    || googleDisplayNameFromSession(session)
    || session?.user?.email
    || "";
  return String(source).trim().charAt(0).toUpperCase() || "I";
}

function renderAvatarFallback(container, profile, session) {
  const fallback = document.createElement("span");
  fallback.className = "profile-avatar-fallback";
  fallback.textContent = profileInitial(profile, session);
  container.replaceChildren(fallback);
}

function renderExternalAvatar(container, profile, session, url) {
  const image = document.createElement("img");
  image.src = url;
  image.alt = "Foto de perfil";
  image.addEventListener("error", () => renderAvatarFallback(container, profile, session), { once: true });
  container.replaceChildren(image);
}

async function getAuthenticatedContext() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  if (!data.session?.user) {
    redirectToLogin();
    return null;
  }
  return { supabase, session: data.session };
}

async function loadOwnProfile(supabase) {
  const { data, error } = await supabase.rpc("shopping_perfil_atual");
  if (error) throw error;
  return data?.[0] || null;
}

async function loadDefaultAddress(supabase) {
  const { data, error } = await supabase.rpc("shopping_endereco_padrao_atual");
  if (error) throw error;
  return data?.[0] || null;
}

export async function resolveAvatarSignedUrl(supabase, avatarPath) {
  if (!avatarPath) return "";
  const { data, error } = await supabase.storage
    .from(AVATAR_BUCKET)
    .createSignedUrl(avatarPath, 60 * 60);
  if (error) throw error;
  return data?.signedUrl || "";
}

async function uploadAvatar(supabase, userId, file) {
  validateAvatar(file);

  const uniqueName = crypto.randomUUID
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const path = `${userId}/${uniqueName}.${fileExtension(file)}`;

  const { error } = await supabase.storage
    .from(AVATAR_BUCKET)
    .upload(path, file, {
      cacheControl: "3600",
      contentType: file.type,
      upsert: false,
    });

  if (error) throw new Error(`Não foi possível salvar a foto: ${error.message}`);
  return path;
}

async function removeAvatar(supabase, avatarPath) {
  if (!avatarPath) return;
  const { error } = await supabase.storage.from(AVATAR_BUCKET).remove([avatarPath]);
  if (error) console.warn(`Não foi possível remover o avatar anterior: ${error.message}`);
}

function setFeedback(element, message, tone = "neutral") {
  if (!element) return;
  element.hidden = false;
  element.textContent = message;
  element.dataset.tone = tone;
}

function isCheckoutProfileFlow() {
  return new URLSearchParams(window.location.search).get("aviso") === "checkout";
}

function safeRedirectTarget() {
  const redirect = new URLSearchParams(window.location.search).get("redirect");
  return redirect === "/carrinho/" ? redirect : "";
}

function profileFromForm(form, session) {
  return {
    nome_completo: getFormValue(form, "nomeCompleto"),
    email_normalizado: getFormValue(form, "email") || session?.user?.email || "",
    telefone_normalizado: getFormValue(form, "telefone"),
  };
}

function addressFromForm(form) {
  return {
    nome_destinatario: getFormValue(form, "nomeDestinatario"),
    cep: getFormValue(form, "cep"),
    logradouro: getFormValue(form, "logradouro"),
    numero: getFormValue(form, "numero"),
    bairro: getFormValue(form, "bairro"),
    cidade: getFormValue(form, "cidade"),
    uf: getFormValue(form, "uf").toUpperCase(),
  };
}

function fieldElement(form, field) {
  const names = {
    nomeCompleto: "nomeCompleto",
    email: "email",
    telefone: "telefone",
    nomeDestinatario: "nomeDestinatario",
    cep: "cep",
    logradouro: "logradouro",
    numero: "numero",
    bairro: "bairro",
    cidade: "cidade",
    uf: "uf",
  };
  return form.elements[names[field]] || null;
}

function updateMissingMessage(element, result) {
  if (!element) return;
  if (result.complete) {
    element.hidden = true;
    element.textContent = "";
    return;
  }

  const labels = result.missingFields.map((field) => CHECKOUT_REQUIRED_FIELD_LABELS[field]);
  element.hidden = false;
  element.textContent = `Pendências: ${labels.join(", ")}.`;
}

function applyCheckoutValidation(form, result, options = {}) {
  const missing = new Set(result.missingFields);
  CHECKOUT_REQUIRED_FIELDS.forEach((field) => {
    const element = fieldElement(form, field);
    if (!element) return;
    const invalid = missing.has(field);
    element.toggleAttribute("aria-invalid", invalid);
    element.classList.toggle("is-invalid", invalid);
  });

  if (options.focusFirstInvalid && result.missingFields.length) {
    const firstInvalid = fieldElement(form, result.missingFields[0]);
    firstInvalid?.focus({ preventScroll: true });
    firstInvalid?.scrollIntoView({ behavior: "smooth", block: "center" });
  }
}

function validateCheckoutForm(form, session, options = {}) {
  const result = validateCheckoutProfile(profileFromForm(form, session), addressFromForm(form), session);
  applyCheckoutValidation(form, result, options);
  updateMissingMessage(document.querySelector("[data-checkout-profile-missing]"), result);
  return result;
}

function showCheckoutNotice(profile, address, form, session) {
  const notice = document.querySelector("[data-checkout-profile-notice]");
  if (!notice || !isCheckoutProfileFlow()) return;

  notice.hidden = false;
  const result = validateCheckoutProfile(profile, address, session);
  applyCheckoutValidation(form, result, { focusFirstInvalid: !result.complete });
  updateMissingMessage(document.querySelector("[data-checkout-profile-missing]"), result);
}

function fillAddressForm(form, address) {
  form.elements.nomeDestinatario.value = address?.nome_destinatario || "";
  form.elements.cep.value = address?.cep || "";
  form.elements.logradouro.value = address?.logradouro || "";
  form.elements.numero.value = address?.numero || "";
  form.elements.complemento.value = address?.complemento || "";
  form.elements.bairro.value = address?.bairro || "";
  form.elements.cidade.value = address?.cidade || "";
  form.elements.uf.value = address?.uf || "";
  form.elements.referencia.value = address?.referencia || "";
}

async function renderCurrentAvatar(supabase, container, profile, session) {
  if (!container) return;

  if (selectedAvatarPreviewUrl) {
    const image = document.createElement("img");
    image.src = selectedAvatarPreviewUrl;
    image.alt = "Prévia da foto de perfil";
    container.replaceChildren(image);
    return;
  }

  if (!profile?.avatar_path || pendingAvatarRemoval) {
    const googleAvatarUrl = googleAvatarUrlFromSession(session);
    if (googleAvatarUrl) {
      renderExternalAvatar(container, profile, session, googleAvatarUrl);
      return;
    }
    renderAvatarFallback(container, profile, session);
    return;
  }

  try {
    const signedUrl = await resolveAvatarSignedUrl(supabase, profile.avatar_path);
    const image = document.createElement("img");
    image.src = signedUrl;
    image.alt = "Foto de perfil";
    image.addEventListener("error", () => renderAvatarFallback(container, profile, session), { once: true });
    container.replaceChildren(image);
  } catch (error) {
    console.warn(error.message);
    renderAvatarFallback(container, profile, session);
  }
}

function fillProfileForm(form, profile, session) {
  currentAvatarPath = profile?.avatar_path || null;
  form.elements.nomeCompleto.value = profile?.nome_completo || "";
  form.elements.email.value = session?.user?.email || profile?.email_normalizado || "";
  form.elements.telefone.value = profile?.telefone_normalizado || "";
  form.elements.pagamentoPreferido.value = PAYMENT_METHODS.has(profile?.pagamento_preferido)
    ? profile.pagamento_preferido
    : "";
}

function readProfileForm(form, avatarPath) {
  const pagamentoPreferido = getFormValue(form, "pagamentoPreferido");
  return {
    p_nome_completo: normalizeOptional(getFormValue(form, "nomeCompleto")),
    p_telefone_normalizado: normalizeOptional(getFormValue(form, "telefone")),
    p_avatar_path: avatarPath,
    p_pagamento_preferido: PAYMENT_METHODS.has(pagamentoPreferido) ? pagamentoPreferido : null,
  };
}

function readAddressForm(form) {
  return {
    p_nome_destinatario: normalizeOptional(getFormValue(form, "nomeDestinatario")),
    p_cep: normalizeOptional(getFormValue(form, "cep")),
    p_logradouro: normalizeOptional(getFormValue(form, "logradouro")),
    p_numero: normalizeOptional(getFormValue(form, "numero")),
    p_complemento: normalizeOptional(getFormValue(form, "complemento")),
    p_bairro: normalizeOptional(getFormValue(form, "bairro")),
    p_cidade: normalizeOptional(getFormValue(form, "cidade")),
    p_uf: normalizeOptional(getFormValue(form, "uf").toUpperCase()),
    p_referencia: normalizeOptional(getFormValue(form, "referencia")),
  };
}

function clearSelectedAvatar(form) {
  if (selectedAvatarPreviewUrl) URL.revokeObjectURL(selectedAvatarPreviewUrl);
  selectedAvatarPreviewUrl = "";
  selectedAvatarFile = null;
  if (form.elements.avatar) form.elements.avatar.value = "";
}

async function saveProfilePage(form, feedback, supabase, session) {
  let uploadedAvatarPath = null;
  const oldAvatarPath = currentAvatarPath;

  try {
    if (selectedAvatarFile) {
      uploadedAvatarPath = await uploadAvatar(supabase, session.user.id, selectedAvatarFile);
    }

    const { data: addressData, error: addressError } = await supabase.rpc(
      "shopping_endereco_padrao_salvar",
      readAddressForm(form),
    );
    if (addressError) throw addressError;

    const nextAvatarPath = pendingAvatarRemoval ? null : (uploadedAvatarPath || currentAvatarPath);
    const { data: profileData, error: profileError } = await supabase.rpc(
      "shopping_perfil_pessoal_salvar",
      readProfileForm(form, nextAvatarPath),
    );
    if (profileError) throw profileError;

    if ((uploadedAvatarPath || pendingAvatarRemoval) && oldAvatarPath && oldAvatarPath !== nextAvatarPath) {
      await removeAvatar(supabase, oldAvatarPath);
    }

    const profile = profileData?.[0] || await loadOwnProfile(supabase);
    const address = addressData?.[0] || null;
    currentAvatarPath = profile?.avatar_path || null;
    pendingAvatarRemoval = false;
    clearSelectedAvatar(form);
    fillProfileForm(form, profile, session);
    fillAddressForm(form, address);
    await renderCurrentAvatar(supabase, document.querySelector("[data-profile-avatar-preview]"), profile, session);
    if (uploadedAvatarPath || pendingAvatarRemoval || oldAvatarPath !== currentAvatarPath) {
      invalidateAuthNavigationCache();
      await initAuthNavigation();
    }
    setFeedback(feedback, "Dados pessoais salvos com sucesso.", "success");
    return { profile, address };
  } catch (error) {
    if (uploadedAvatarPath) await removeAvatar(supabase, uploadedAvatarPath);
    setFeedback(feedback, error.message || "Não foi possível salvar seus dados.", "error");
    return null;
  }
}

export async function initProfilePage() {
  const form = document.querySelector("[data-profile-form]");
  const feedback = document.querySelector("[data-profile-feedback]");
  const avatarPreview = document.querySelector("[data-profile-avatar-preview]");
  if (!form) return;

  try {
    const context = await getAuthenticatedContext();
    if (!context) return;

    const { supabase, session } = context;
    const [profile, address] = await Promise.all([
      loadOwnProfile(supabase),
      loadDefaultAddress(supabase),
    ]);

    fillProfileForm(form, profile, session);
    fillAddressForm(form, address);
    await renderCurrentAvatar(supabase, avatarPreview, profile, session);
    setFeedback(feedback, "Dados carregados.", "neutral");
    showCheckoutNotice(profile, address, form, session);

    CHECKOUT_REQUIRED_FIELDS.forEach((field) => {
      const element = fieldElement(form, field);
      element?.addEventListener("input", () => {
        if (isCheckoutProfileFlow()) validateCheckoutForm(form, session);
      });
    });

    form.elements.avatar?.addEventListener("change", () => {
      try {
        const file = form.elements.avatar.files?.[0] || null;
        validateAvatar(file);
        clearSelectedAvatar(form);
        selectedAvatarFile = file;
        selectedAvatarPreviewUrl = file ? URL.createObjectURL(file) : "";
        pendingAvatarRemoval = false;
        renderCurrentAvatar(supabase, avatarPreview, profile, session);
      } catch (error) {
        clearSelectedAvatar(form);
        setFeedback(feedback, error.message, "error");
      }
    });

    form.querySelector("[data-avatar-remove]")?.addEventListener("click", () => {
      clearSelectedAvatar(form);
      pendingAvatarRemoval = true;
      renderAvatarFallback(avatarPreview, profile, session);
    });

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (isCheckoutProfileFlow()) {
        const result = validateCheckoutForm(form, session, { focusFirstInvalid: true });
        if (!result.complete) {
          setFeedback(feedback, "Complete os campos obrigatórios destacados para continuar.", "error");
          return;
        }
      }

      setFeedback(feedback, "Salvando dados.", "neutral");
      const saved = await saveProfilePage(form, feedback, supabase, session);
      if (!saved || !isCheckoutProfileFlow()) return;

      const [persistedProfile, persistedAddress] = await Promise.all([
        loadOwnProfile(supabase),
        loadDefaultAddress(supabase),
      ]);
      const result = validateCheckoutProfile(persistedProfile, persistedAddress, session);
      applyCheckoutValidation(form, result, { focusFirstInvalid: !result.complete });
      updateMissingMessage(document.querySelector("[data-checkout-profile-missing]"), result);
      if (!result.complete) {
        setFeedback(feedback, "Ainda há dados obrigatórios pendentes. Revise os campos destacados.", "error");
        return;
      }

      const redirect = safeRedirectTarget();
      setFeedback(feedback, "Dados salvos. Voltando ao carrinho.", "success");
      if (redirect) window.location.href = redirect;
    });
  } catch (error) {
    setFeedback(feedback, error.message || "Não foi possível carregar seus dados.", "error");
  }
}
