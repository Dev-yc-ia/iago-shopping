import { APP_CONFIG } from "../config/app.js";
import { mountUserMenu, unmountUserMenu } from "../ui/userMenu.js";
import { recordEvent } from "../utils/analytics.js";

let supabaseClientPromise;
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);
const AVATAR_BUCKET = "shopping-avatars";

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
    ? [
        { label: "backend local", url: apiSource },
        { label: "JSON público", url: staticSource },
      ]
    : [
        { label: "JSON público", url: staticSource },
        { label: "backend/API", url: apiSource },
      ];
}

function pageRedirectUrl(pageName) {
  return new URL(pageName, window.location.href).href;
}

function compactText(value) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, 160);
}

function describePublicConfig(config) {
  const missing = [];
  if (!config || typeof config !== "object") missing.push("JSON inválido");
  if (!config?.supabase_url) missing.push("supabase_url");
  if (!config?.supabase_anon_key) missing.push("supabase_anon_key");
  if (!config?.supabase_configured) missing.push("supabase_configured=true");
  return missing;
}

function buildPublicConfigError(attempts) {
  const environment = isLocalHttpHost() ? "local" : "publicado/GitHub Pages";
  const details = attempts
    .map((attempt) => `- ${attempt.label}: ${attempt.url} -> ${attempt.reason}`)
    .join("\n");

  return [
    "Não foi possível carregar a configuração pública do Supabase.",
    "",
    `Ambiente detectado: ${environment}`,
    `Página atual: ${window.location.href}`,
    "",
    "Tentativas:",
    details,
  ].join("\n");
}

async function fetchPublicConfig(source) {
  const response = await fetch(source.url, {
    headers: { Accept: "application/json" },
    cache: "no-store",
  });

  const body = await response.text();
  if (!response.ok) {
    const preview = compactText(body);
    throw new Error(
      `HTTP ${response.status} ${response.statusText || ""}${
        preview ? ` | resposta: ${preview}` : ""
      }`
    );
  }

  try {
    return JSON.parse(body);
  } catch (error) {
    throw new Error(`JSON inválido ou vazio | resposta: ${compactText(body)}`);
  }
}

async function loadPublicConfig() {
  const attempts = [];

  for (const source of publicConfigSources()) {
    try {
      const config = await fetchPublicConfig(source);
      const missing = describePublicConfig(config);
      if (missing.length) {
        throw new Error(`campos ausentes ou inválidos: ${missing.join(", ")}`);
      }

      console.info(`Configuração pública do Supabase carregada via ${source.label}.`);
      return config;
    } catch (error) {
      attempts.push({
        label: source.label,
        url: source.url,
        reason: error.message,
      });
      console.warn(`Falha ao carregar configuração pública via ${source.label}: ${error.message}`);
    }
  }

  throw new Error(buildPublicConfigError(attempts));
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

export async function signInWithGoogle(redirectPath = "/login/") {
  const supabase = await getSupabaseClient();
  const { error } = await supabase.auth.signInWithOAuth({
    provider: "google",
    options: {
      redirectTo: pageRedirectUrl(redirectPath),
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
    redirectTo: pageRedirectUrl("/nova-senha/"),
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

async function resolveAvatarUrl(supabase, avatarPath) {
  if (!avatarPath) return "";

  const { data, error } = await supabase.storage
    .from(AVATAR_BUCKET)
    .createSignedUrl(avatarPath, 60 * 60);

  if (error) {
    console.warn(error.message);
    return "";
  }

  return data?.signedUrl || "";
}

function normalizeLoginLinks(nav) {
  const links = Array.from(nav.querySelectorAll("a"));
  return links.filter((link) => {
    const href = link.getAttribute("href");
    const text = link.textContent.trim().toLowerCase();
    const isLoginHref = href === "/login/";
    const isLegacyEntryHref = href === "/" && (text === "entrada" || text === "login");
    if (isLoginHref || isLegacyEntryHref) {
      link.href = "/login/";
      link.textContent = "Login";
      return true;
    }
    return false;
  });
}

function resetDynamicNavigation(nav) {
  unmountUserMenu();
  nav.querySelectorAll("[data-auth-dynamic]").forEach((element) => element.remove());
  nav.querySelector("[data-user-menu-root]")?.remove();
}

function appendAuthenticatedLink(nav, href, label, datasetKey) {
  const link = document.createElement("a");
  link.href = href;
  link.textContent = label;
  link.dataset.authDynamic = "true";
  link.dataset[datasetKey] = "true";
  nav.append(link);
}

export async function requireAdminAccess() {
  const authState = await recoverSessionProfile();
  if (!canAccessAdmin(authState.profile)) {
    window.location.href = "/login/";
    return null;
  }

  return authState;
}

export async function initAuthNavigation() {
  const nav = document.querySelector(".top-nav");
  if (!nav) return;

  resetDynamicNavigation(nav);
  const loginLinks = normalizeLoginLinks(nav);
  const adminLink = nav.querySelector('a[href$="/admin/"]');
  if (adminLink) {
    adminLink.hidden = true;
  }

  try {
    const { session, profile } = await recoverSessionProfile();
    if (adminLink) {
      adminLink.hidden = !canAccessAdmin(profile);
    }

    if (!session) {
      loginLinks.forEach((link) => {
        link.hidden = false;
      });
      return;
    }

    loginLinks.forEach((link) => {
      link.hidden = true;
    });

    appendAuthenticatedLink(nav, "/pedidos/", "Pedidos", "ordersLink");
    appendAuthenticatedLink(nav, "/carrinho/", "Carrinho", "cartLink");

    const supabase = await getSupabaseClient();
    const avatarUrl = await resolveAvatarUrl(supabase, profile?.avatar_path);
    mountUserMenu(nav, {
      profile,
      session,
      avatarUrl,
      onSignOut: async () => {
        await signOut();
        window.location.href = "/login/";
      },
    });
  } catch (error) {
    console.warn(error.message);
  }
}
