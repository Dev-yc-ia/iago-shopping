import { APP_CONFIG } from "../config/app.js";
import { mountUserMenu, unmountUserMenu } from "../ui/userMenu.js";
import { recordEvent } from "../utils/analytics.js";

let supabaseClientPromise;
let lastAuthNavigationSignature = "";
let authNavigationSubscription = null;
let cartBadgeRefreshHandler = null;
let cartBadgeRequestId = 0;
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);
const AVATAR_BUCKET = "shopping-avatars";
const AUTH_NAVIGATION_CACHE_KEY = "iago-shopping-auth-navigation-state";
const HEADER_CART_REFRESH_EVENT = "iago:cart:updated";
const AVATAR_SIGNED_URL_TTL_SECONDS = 7 * 24 * 60 * 60;
const GOOGLE_METADATA_AVATAR_KEYS = ["avatar_url", "picture"];
const GOOGLE_METADATA_NAME_KEYS = ["full_name", "name", "nome_exibicao"];

function normalizeEmail(value) {
  return String(value || "").trim().toLowerCase();
}

function displayNameFromEmail(email) {
  return email.split("@")[0] || "Cliente IAGO";
}

function firstMetadataText(metadata, keys) {
  for (const key of keys) {
    const value = String(metadata?.[key] || "").trim();
    if (value) return value;
  }
  return "";
}

function sessionProvider(session) {
  const user = session?.user;
  const appProvider = String(user?.app_metadata?.provider || "").toLowerCase();
  if (appProvider) return appProvider;

  const identityProvider = user?.identities
    ?.map((identity) => String(identity?.provider || "").toLowerCase())
    ?.find(Boolean);
  return identityProvider || "";
}

function isGoogleSession(session) {
  return sessionProvider(session) === "google"
    || Boolean(session?.user?.identities?.some((identity) => identity?.provider === "google"));
}

export function googleDisplayNameFromSession(session) {
  return firstMetadataText(session?.user?.user_metadata, GOOGLE_METADATA_NAME_KEYS);
}

export function googleAvatarUrlFromSession(session) {
  const url = firstMetadataText(session?.user?.user_metadata, GOOGLE_METADATA_AVATAR_KEYS);
  if (!url) return "";

  try {
    const parsed = new URL(url);
    return parsed.protocol === "https:" ? parsed.href : "";
  } catch {
    return "";
  }
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

async function syncGoogleProfileIfNeeded(supabase, session, profile) {
  if (!session?.user || !isGoogleSession(session)) return profile;

  const googleName = googleDisplayNameFromSession(session);
  const sessionEmail = normalizeEmail(session.user.email);
  const needsName = googleName && (!profile?.nome_completo || !profile?.nome_exibicao);
  const needsEmail = sessionEmail && profile?.email_normalizado !== sessionEmail;

  if (!needsName && !needsEmail) return profile;

  const { data, error } = await supabase.rpc("shopping_perfil_oauth_sincronizar", {
    p_nome_google: googleName || null,
    p_email_normalizado: sessionEmail || null,
  });

  if (error) throw error;
  return data?.[0] || profile;
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

export async function signUpParceiro(access, password) {
  const email = normalizeEmail(access);
  if (!email.includes("@")) {
    throw new Error("Informe um e-mail válido para criar a conta parceira.");
  }

  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      data: {
        nome_exibicao: displayNameFromEmail(email),
        origem: "cadastro_parceiro",
      },
    },
  });
  if (error) throw error;

  recordEvent("signup_success", { source: "partner_email" });
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

export async function submitPartnerApplication(application) {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_parceiro_solicitar_cadastro", {
    p_tipo_pessoa: application.tipoPessoa,
    p_documento_normalizado: application.documento,
    p_nome: application.nome,
    p_nome_loja: application.nomeLoja || null,
    p_telefone_normalizado: application.telefone || null,
    p_aceite: application.aceite,
    p_user_agent: application.userAgent || null,
  });
  if (error) throw error;
  return data?.[0] || data;
}

export async function listPartnerApplications() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_admin_listar_solicitacoes_parceiro");
  if (error) throw error;
  return data || [];
}

export async function decidePartnerApplication(applicationId, decision, reason = "") {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_admin_decidir_solicitacao_parceiro", {
    p_solicitacao_id: applicationId,
    p_decisao: decision,
    p_motivo: reason,
  });
  if (error) throw error;
  return data?.[0] || data;
}

export async function signOut() {
  clearAuthNavigationCache();
  lastAuthNavigationSignature = "";
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
  const profile = await syncGoogleProfileIfNeeded(supabase, session, await getOwnProfile(supabase));
  return { session, profile };
}

export function canAccessAdmin(profile) {
  return (
    profile?.status_ativacao === "ativo" &&
    ["master", "funcionario", "parceiro"].includes(profile.papel)
  );
}

async function resolveAvatarUrl(supabase, avatarPath) {
  if (!avatarPath) return { url: "", expiresAt: 0 };

  const { data, error } = await supabase.storage
    .from(AVATAR_BUCKET)
    .createSignedUrl(avatarPath, AVATAR_SIGNED_URL_TTL_SECONDS);

  if (error) {
    console.warn(error.message);
    return { url: "", expiresAt: 0 };
  }

  return {
    url: data?.signedUrl || "",
    expiresAt: data?.signedUrl ? Date.now() + (AVATAR_SIGNED_URL_TTL_SECONDS * 1000) : 0,
  };
}

function canReuseCachedAvatarUrl(state, profile, session) {
  if (state?.status !== "authenticated" || !state.avatarUrl) return false;
  return state.userId === (session?.user?.id || "")
    && state.avatarPath === (profile?.avatar_path || "")
    && state.googleAvatarUrl === googleAvatarUrlFromSession(session);
}

async function resolveUserAvatarUrl(supabase, profile, session, previousState) {
  const googleAvatarUrl = googleAvatarUrlFromSession(session);
  if (!profile?.avatar_path) return { avatarUrl: googleAvatarUrl, expiresAt: 0 };

  if (canReuseCachedAvatarUrl(previousState, profile, session)) {
    return {
      avatarUrl: previousState.avatarUrl,
      expiresAt: previousState.expiresAt || 0,
    };
  }

  const storedAvatar = await resolveAvatarUrl(supabase, profile.avatar_path);
  return {
    avatarUrl: storedAvatar.url || googleAvatarUrl,
    expiresAt: storedAvatar.expiresAt,
  };
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

function safeSessionStorage() {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

function profileDisplayName(profile, session) {
  return profile?.nome_completo
    || profile?.nome_exibicao
    || googleDisplayNameFromSession(session)
    || session?.user?.email
    || "";
}

function makeAuthNavigationState(session, profile, avatarUrl = "", avatarExpiresAt = 0) {
  if (!session?.user) {
    return { version: 1, status: "guest" };
  }

  return {
    version: 1,
    status: "authenticated",
    userId: session.user.id || "",
    email: session.user.email || "",
    displayName: profileDisplayName(profile, session),
    papel: profile?.papel || "",
    statusAtivacao: profile?.status_ativacao || "",
    avatarPath: profile?.avatar_path || "",
    googleAvatarUrl: googleAvatarUrlFromSession(session),
    avatarUrl,
    expiresAt: avatarExpiresAt,
  };
}

function authNavigationSignature(state) {
  if (state?.status !== "authenticated") return "guest";
  return JSON.stringify({
    status: state.status,
    userId: state.userId,
    email: state.email,
    displayName: state.displayName,
    papel: state.papel,
    statusAtivacao: state.statusAtivacao,
    avatarPath: state.avatarPath,
    googleAvatarUrl: state.googleAvatarUrl,
  });
}

function cachedSessionFromState(state) {
  return {
    user: {
      id: state.userId,
      email: state.email,
      user_metadata: {
        full_name: state.displayName,
        picture: state.googleAvatarUrl || "",
      },
    },
  };
}

function cachedProfileFromState(state) {
  return {
    nome_completo: state.displayName,
    nome_exibicao: state.displayName,
    papel: state.papel,
    status_ativacao: state.statusAtivacao,
    avatar_path: state.avatarPath,
  };
}

function readAuthNavigationCache() {
  const storage = safeSessionStorage();
  if (!storage) return null;

  try {
    const state = JSON.parse(storage.getItem(AUTH_NAVIGATION_CACHE_KEY) || "null");
    if (state?.version !== 1 || state.status !== "authenticated") return null;
    return state;
  } catch {
    return null;
  }
}

function writeAuthNavigationCache(state) {
  const storage = safeSessionStorage();
  if (!storage) return;

  try {
    if (state?.status === "authenticated") {
      storage.setItem(AUTH_NAVIGATION_CACHE_KEY, JSON.stringify(state));
      return;
    }
    storage.removeItem(AUTH_NAVIGATION_CACHE_KEY);
  } catch {
    // Cache visual temporário; falhas não devem impedir autenticação.
  }
}

function clearAuthNavigationCache() {
  writeAuthNavigationCache({ version: 1, status: "guest" });
}

export function invalidateAuthNavigationCache() {
  clearAuthNavigationCache();
  lastAuthNavigationSignature = "";
}

function createHeaderCartIcon() {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "header-cart-icon");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.8");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");

  const cart = document.createElementNS("http://www.w3.org/2000/svg", "path");
  cart.setAttribute("d", "M6.5 7.5h14l-1.4 7.1a2 2 0 0 1-2 1.6H9.2a2 2 0 0 1-2-1.7L5.8 4.8H3.5");

  const wheelLeft = document.createElementNS("http://www.w3.org/2000/svg", "circle");
  wheelLeft.setAttribute("cx", "9.5");
  wheelLeft.setAttribute("cy", "20");
  wheelLeft.setAttribute("r", "1.2");

  const wheelRight = document.createElementNS("http://www.w3.org/2000/svg", "circle");
  wheelRight.setAttribute("cx", "17.5");
  wheelRight.setAttribute("cy", "20");
  wheelRight.setAttribute("r", "1.2");

  svg.append(cart, wheelLeft, wheelRight);
  return svg;
}

function appendHeaderCartLink(nav) {
  const link = document.createElement("a");
  link.href = "/carrinho/";
  link.className = "header-cart-link";
  link.dataset.authDynamic = "true";
  link.dataset.cartLink = "true";
  link.setAttribute("aria-label", "Carrinho");

  const badge = document.createElement("span");
  badge.className = "header-cart-badge";
  badge.dataset.cartBadge = "true";
  badge.hidden = true;

  link.append(createHeaderCartIcon(), badge);
  nav.append(link);
}

async function loadHeaderCartQuantity() {
  const supabase = await getSupabaseClient();
  const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
  if (sessionError) throw sessionError;
  if (!sessionData.session?.user) return 0;

  const { data, error } = await supabase.rpc("shopping_carrinho_atual");
  if (error) throw error;

  return (data || []).reduce((total, item) => total + Number(item.quantidade || 0), 0);
}

export async function updateHeaderCartBadge() {
  const link = document.querySelector("[data-cart-link]");
  const badge = document.querySelector("[data-cart-badge]");
  if (!link || !badge) return;

  const requestId = ++cartBadgeRequestId;
  try {
    const quantity = await loadHeaderCartQuantity();
    if (requestId !== cartBadgeRequestId) return;

    badge.hidden = quantity <= 0;
    badge.textContent = quantity > 0 ? String(quantity) : "";
    link.setAttribute(
      "aria-label",
      quantity > 0
        ? `Carrinho, ${quantity} ${quantity === 1 ? "item" : "itens"}`
        : "Carrinho"
    );
  } catch (error) {
    if (requestId !== cartBadgeRequestId) return;

    badge.hidden = true;
    badge.textContent = "";
    link.setAttribute("aria-label", "Carrinho");
    console.warn(error.message);
  }
}

function renderAuthNavigationState(nav, loginLinks, adminLink, state) {
  const signature = authNavigationSignature(state);
  if (signature === lastAuthNavigationSignature) {
    writeAuthNavigationCache(state);
    if (state.status === "authenticated") {
      updateHeaderCartBadge();
    }
    return;
  }

  resetDynamicNavigation(nav);
  lastAuthNavigationSignature = signature;

  if (state.status !== "authenticated") {
    loginLinks.forEach((link) => {
      link.hidden = false;
    });
    if (adminLink) adminLink.hidden = true;
    clearAuthNavigationCache();
    return;
  }

  const profile = cachedProfileFromState(state);
  const session = cachedSessionFromState(state);
  loginLinks.forEach((link) => {
    link.hidden = true;
  });
  if (adminLink) {
    adminLink.hidden = !canAccessAdmin(profile);
  }

  appendHeaderCartLink(nav);
  mountUserMenu(nav, {
    profile,
    session,
    avatarUrl: state.avatarUrl || state.googleAvatarUrl || "",
    onSignOut: async () => {
      await signOut();
      window.location.href = "/login/";
    },
  });
  updateHeaderCartBadge();
  writeAuthNavigationCache(state);
}

async function resolveAuthNavigationState(sessionOverride, previousState = readAuthNavigationCache()) {
  const supabase = await getSupabaseClient();
  const session = sessionOverride === undefined ? await getSession() : sessionOverride;
  if (!session?.user) return makeAuthNavigationState(null, null);

  const profile = await syncGoogleProfileIfNeeded(supabase, session, await getOwnProfile(supabase));
  const avatar = await resolveUserAvatarUrl(supabase, profile, session, previousState);
  return makeAuthNavigationState(session, profile, avatar.avatarUrl, avatar.expiresAt);
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

  const loginLinks = normalizeLoginLinks(nav);
  const adminLink = nav.querySelector('a[href$="/admin/"]');
  if (adminLink) {
    adminLink.hidden = true;
  }

  const cachedState = readAuthNavigationCache();
  if (cachedState) {
    renderAuthNavigationState(nav, loginLinks, adminLink, cachedState);
  }

  try {
    renderAuthNavigationState(nav, loginLinks, adminLink, await resolveAuthNavigationState(undefined, cachedState));

    const supabase = await getSupabaseClient();
    authNavigationSubscription?.unsubscribe();
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === "INITIAL_SESSION") return;
      resolveAuthNavigationState(session, readAuthNavigationCache())
        .then((state) => renderAuthNavigationState(nav, loginLinks, adminLink, state))
        .catch((error) => console.warn(error.message));
    });
    authNavigationSubscription = data?.subscription || null;
    if (cartBadgeRefreshHandler) {
      window.removeEventListener(HEADER_CART_REFRESH_EVENT, cartBadgeRefreshHandler);
    }
    cartBadgeRefreshHandler = () => {
      updateHeaderCartBadge();
    };
    window.addEventListener(HEADER_CART_REFRESH_EVENT, cartBadgeRefreshHandler);
  } catch (error) {
    console.warn(error.message);
  }
}
