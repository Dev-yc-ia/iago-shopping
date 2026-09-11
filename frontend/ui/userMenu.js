let cleanupCurrentMenu = null;
const GOOGLE_METADATA_NAME_KEYS = ["full_name", "name", "nome_exibicao"];

export function unmountUserMenu() {
  if (!cleanupCurrentMenu) return;
  cleanupCurrentMenu();
  cleanupCurrentMenu = null;
}

function profileInitial(profile, session) {
  const metadata = session?.user?.user_metadata;
  const googleName = GOOGLE_METADATA_NAME_KEYS
    .map((key) => String(metadata?.[key] || "").trim())
    .find(Boolean);
  const source = profile?.nome_completo
    || profile?.nome_exibicao
    || googleName
    || session?.user?.email
    || "";
  return String(source).trim().charAt(0).toUpperCase() || "I";
}

function closeMenu(root, focusButton = false) {
  const button = root.querySelector("[data-user-menu-button]");
  const dropdown = root.querySelector("[data-user-menu-dropdown]");
  button?.setAttribute("aria-expanded", "false");
  dropdown.hidden = true;
  if (focusButton) button?.focus();
}

function openMenu(root) {
  const button = root.querySelector("[data-user-menu-button]");
  const dropdown = root.querySelector("[data-user-menu-dropdown]");
  button.setAttribute("aria-expanded", "true");
  dropdown.hidden = false;
}

function toggleMenu(root) {
  const button = root.querySelector("[data-user-menu-button]");
  if (button.getAttribute("aria-expanded") === "true") {
    closeMenu(root);
    return;
  }
  openMenu(root);
}

function isTouchActivation(event) {
  return event.type === "touchend"
    || event.pointerType === "touch"
    || event.pointerType === "pen";
}

function runTouchAction(event, action) {
  if (!isTouchActivation(event)) return;
  event.preventDefault();
  event.stopPropagation();
  action();
}

export function mountUserMenu(nav, { profile, session, avatarUrl, onSignOut }) {
  unmountUserMenu();

  nav.querySelector("[data-user-menu-root]")?.remove();

  const root = document.createElement("div");
  root.className = "user-menu";
  root.dataset.userMenuRoot = "true";

  const menuId = `user-menu-${crypto.randomUUID ? crypto.randomUUID() : Date.now()}`;
  const button = document.createElement("button");
  button.className = "user-avatar-button";
  button.type = "button";
  button.dataset.userMenuButton = "true";
  button.setAttribute("aria-haspopup", "menu");
  button.setAttribute("aria-expanded", "false");
  button.setAttribute("aria-controls", menuId);
  button.setAttribute("aria-label", "Abrir menu do usuário");

  if (avatarUrl) {
    const image = document.createElement("img");
    image.className = "user-avatar-image";
    image.decoding = "sync";
    image.loading = "eager";
    image.src = avatarUrl;
    image.alt = "";
    image.addEventListener("error", () => {
      image.remove();
      const fallback = document.createElement("span");
      fallback.className = "user-avatar-fallback";
      fallback.textContent = profileInitial(profile, session);
      button.append(fallback);
    }, { once: true });
    button.append(image);
  } else {
    const fallback = document.createElement("span");
    fallback.className = "user-avatar-fallback";
    fallback.textContent = profileInitial(profile, session);
    button.append(fallback);
  }

  const dropdown = document.createElement("div");
  dropdown.className = "user-menu-dropdown";
  dropdown.id = menuId;
  dropdown.dataset.userMenuDropdown = "true";
  dropdown.role = "menu";
  dropdown.hidden = true;

  const profileLink = document.createElement("a");
  profileLink.className = "user-menu-item";
  profileLink.href = "/dados-pessoais/";
  profileLink.role = "menuitem";
  profileLink.textContent = "Dados pessoais";
  const openProfilePage = (event) => runTouchAction(event, () => {
    window.location.assign(profileLink.href);
  });
  profileLink.addEventListener("pointerup", openProfilePage);
  profileLink.addEventListener("touchend", openProfilePage, { passive: false });

  const ordersLink = document.createElement("a");
  ordersLink.className = "user-menu-item";
  ordersLink.href = "/pedidos/";
  ordersLink.role = "menuitem";
  ordersLink.textContent = "Pedidos";
  const openOrdersPage = (event) => runTouchAction(event, () => {
    window.location.assign(ordersLink.href);
  });
  ordersLink.addEventListener("pointerup", openOrdersPage);
  ordersLink.addEventListener("touchend", openOrdersPage, { passive: false });

  const logoutButton = document.createElement("button");
  logoutButton.className = "user-menu-item";
  logoutButton.type = "button";
  logoutButton.role = "menuitem";
  logoutButton.textContent = "Sair";

  let isSigningOut = false;
  const handleSignOut = async () => {
    if (isSigningOut) return;
    isSigningOut = true;
    logoutButton.disabled = true;
    try {
      await onSignOut();
    } catch (error) {
      isSigningOut = false;
      logoutButton.disabled = false;
      console.warn(error.message);
    }
  };
  const touchSignOut = (event) => runTouchAction(event, handleSignOut);
  logoutButton.addEventListener("pointerup", touchSignOut);
  logoutButton.addEventListener("touchend", touchSignOut, { passive: false });
  logoutButton.addEventListener("click", handleSignOut);

  dropdown.append(profileLink, ordersLink, logoutButton);
  root.append(button, dropdown);
  nav.append(root);

  const onButtonClick = () => toggleMenu(root);
  const onDocumentClick = (event) => {
    if (!root.contains(event.target)) closeMenu(root);
  };
  const onKeydown = (event) => {
    if (event.key === "Escape") {
      closeMenu(root, true);
    }
  };
  const onDocumentFocusin = (event) => {
    if (!root.contains(event.target)) closeMenu(root);
  };

  button.addEventListener("click", onButtonClick);
  document.addEventListener("click", onDocumentClick);
  document.addEventListener("keydown", onKeydown);
  document.addEventListener("focusin", onDocumentFocusin);

  cleanupCurrentMenu = () => {
    button.removeEventListener("click", onButtonClick);
    document.removeEventListener("click", onDocumentClick);
    document.removeEventListener("keydown", onKeydown);
    document.removeEventListener("focusin", onDocumentFocusin);
    root.remove();
  };
}
