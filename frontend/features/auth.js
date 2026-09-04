import { APP_CONFIG } from "../config/app.js";
import { recordEvent } from "../utils/analytics.js";

let supabaseClientPromise;
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

function normalizeEmail(value) {
  return String(value || "").trim().toLowerCase();
}

function displayNameFromEmail(email) {
  return email.split("@")[0] || "Cliente IAGO";
}

function isLocalHttpHost() {
  return LOCAL_HOSTS.has(window.location.hostname);
}

function publicConfigSources() {
  const apiSource = APP_CONFIG.publicConfigEndpoint;
  const staticSource = APP_CONFIG.publicConfigStaticPath;

  return isLocalHttpHost()
    ? [apiSource, staticSource]
    : [staticSource, apiSource];
}

function pageRedirectUrl(pageName) {
  return new URL(pageName, window.location.href).href;
}

async function fetchPublicConfig(source) {
  const response = await fetch(source, {
    headers: { Accept: "application/json" },
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(`Configuração pública indisponível em ${source}.`);
  }

  return response.json();
}

async function loadPublicConfig() {
  let lastError;

  for (const source of publicConfigSources()) {
    try {
      const config = await fetchPublicConfig(source);
      if (!config.supabase_configured) {
        throw new Error("Supabase ainda não configurado na configuração pública.");
      }

      return config;
    } catch (error) {
      lastError = error;
      console.warn(error.message);
    }
  }

  if (lastError) {
    console.warn(lastError.message);
  }

  throw new Error("Não foi possível carregar a configuração pública do Supabase.");
}

function assertPublicConfig(config) {
  if (!config.supabase_configured) {
    throw new Error("Supabase ainda não configurado na configuração pública.");
  }
}

export async function getSupabaseClient() {
  if (!supabaseClientPromise) {
    supabaseClientPromise = (async () => {
      const [{ createClient }, config] = await Promise.all([
        import("https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm"),
        loadPublicConfig(),
      ]);
      assertPublicConfig(config);

      return createClient(config.supabase_url, config.supabase_anon_key, {
        auth: {
          autoRefreshToken: true,
          detectSessionInUrl: true,
          persistSession: true,
        },
      });
    })().catch((error) => {
      supabaseClientPromise = undefined;
      throw error;
    });
  }

  return supabaseClientPromise;
}

async function getSession() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  return data.session;
}

export async function getCurrentSession() {
  return getSession();
}

async function getOwnProfile(supabase) {
  const { data, error } = await supabase.rpc("shopping_perfil_atual");

  if (error) throw error;
  return data?.[0] || null;
}

export async function listAdminProfiles() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_admin_listar_perfis");
  if (error) throw error;
  return data || [];
}

export async function setProfileRole(userId, papel, motivo) {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_admin_definir_papel", {
    p_user_id: userId,
    p_papel: papel,
    p_motivo: motivo,
  });
  if (error) throw error;
  return data;
}

export async function setProfileActivationStatus(userId, statusAtivacao, motivo) {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_admin_definir_status_ativacao", {
    p_user_id: userId,
    p_status_ativacao: statusAtivacao,
    p_motivo: motivo,
  });
  if (error) throw error;
  return data;
}

export async function signInWithPassword(access, password) {
  const email = normalizeEmail(access);
  if (!email.includes("@")) {
    throw new Error("Use o e-mail cadastrado para entrar.");
  }

  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;

  if (data.user) {
    await getOwnProfile(supabase);
  }

  recordEvent("login_success", { source: "supabase_password" });
  return data;
}

export async function signUpCliente(access, password) {
  const email = normalizeEmail(access);
  if (!email.includes("@")) {
    throw new Error("Informe um e-mail válido para criar a conta.");
  }

  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      data: {
        nome_exibicao: displayNameFromEmail(email),
        origem: "cadastro_direto",
      },
    },
  });
  if (error) throw error;

  recordEvent("signup_success", { source: "supabase_email" });
  return data;
}

export async function signInWithGoogle() {
  const supabase = await getSupabaseClient();
  const { error } = await supabase.auth.signInWithOAuth({
    provider: "google",
    options: {
      redirectTo: pageRedirectUrl("login.html"),
    },
  });

  if (error) throw error;
  recordEvent("login_start", { source: "supabase_google" });
}

export async function signOut() {
  const supabase = await getSupabaseClient();
  const { error } = await supabase.auth.signOut();
  if (error) throw error;
  recordEvent("logout", { source: "supabase" });
}

export async function resetPasswordForEmail(email) {
  const normalizedEmail = normalizeEmail(email);
  if (!normalizedEmail.includes("@")) {
    throw new Error("Informe um e-mail válido.");
  }

  const supabase = await getSupabaseClient();
  const { error } = await supabase.auth.resetPasswordForEmail(normalizedEmail, {
    redirectTo: pageRedirectUrl("nova-senha.html"),
  });
  if (error) throw error;

  recordEvent("password_reset_requested", { source: "supabase_email" });
}

export async function recoverPasswordSession() {
  const supabase = await getSupabaseClient();
  const code = new URLSearchParams(window.location.search).get("code");
  if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) throw error;
  }

  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  return data.session;
}

export async function updatePassword(password) {
  const supabase = await getSupabaseClient();
  const { error } = await supabase.auth.updateUser({ password });
  if (error) throw error;

  recordEvent("password_reset_completed", { source: "supabase_email" });
}

export async function recoverSessionProfile() {
  const session = await getSession();
  if (!session?.user) return { session: null, profile: null };

  const supabase = await getSupabaseClient();
  const profile = await getOwnProfile(supabase);
  return { session, profile };
}

export function canAccessAdmin(profile) {
  return (
    profile?.status_ativacao === "ativo" &&
    ["master", "funcionario", "parceiro"].includes(profile.papel)
  );
}

export async function requireAdminAccess() {
  const authState = await recoverSessionProfile();
  if (!canAccessAdmin(authState.profile)) {
    window.location.href = "./login.html";
    return null;
  }

  return authState;
}

export async function initAuthNavigation() {
  const nav = document.querySelector(".top-nav");
  if (!nav) return;

  const adminLink = nav.querySelector('a[href$="admin.html"]');
  if (adminLink) {
    adminLink.hidden = true;
  }

  try {
    const { session, profile } = await recoverSessionProfile();
    if (adminLink) {
      adminLink.hidden = !canAccessAdmin(profile);
    }
    if (!session) return;

    const ordersLink = document.createElement("a");
    ordersLink.href = "./pedidos.html";
    ordersLink.textContent = "Pedidos";
    ordersLink.dataset.ordersLink = "true";
    nav.append(ordersLink);

    const cartLink = document.createElement("a");
    cartLink.href = "./carrinho.html";
    cartLink.textContent = "Carrinho";
    cartLink.dataset.cartLink = "true";
    nav.append(cartLink);

    const logoutButton = document.createElement("button");
    logoutButton.className = "button ghost";
    logoutButton.type = "button";
    logoutButton.textContent = "Sair";
    logoutButton.addEventListener("click", async () => {
      await signOut();
      window.location.href = "./index.html";
    });
    nav.append(logoutButton);
  } catch (error) {
    console.warn(error.message);
  }
}
