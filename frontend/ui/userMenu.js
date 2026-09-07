let cleanupCurrentMenu = null;

export function unmountUserMenu() {
  if (!cleanupCurrentMenu) return;
  cleanupCurrentMenu();
  cleanupCurrentMenu = null;
}

function profileInitial(profile, session) {
  const source = profile?.nome_completo
    || profile?.nome_exibicao
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
  dropdown.querySelector("[role='menuitem']")?.focus();
}

function toggleMenu(root) {
  const button = root.querySelector("[data-user-menu-button]");
  if (button.getAttribute("aria-expanded") === "true") {
    closeMenu(root);
    return;
  }
  openMenu(root);
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

  const logoutButton = document.createElement("button");
  logoutButton.className = "user-menu-item";
  logoutButton.type = "button";
  logoutButton.role = "menuitem";
  logoutButton.textContent = "Sair";
  logoutButton.addEventListener("click", async () => {
    await onSignOut();
  });

  dropdown.append(profileLink, logoutButton);
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
  const onFocusout = (event) => {
    if (!root.contains(event.relatedTarget)) closeMenu(root);
  };

  button.addEventListener("click", onButtonClick);
  document.addEventListener("click", onDocumentClick);
  document.addEventListener("keydown", onKeydown);
  root.addEventListener("focusout", onFocusout);

  cleanupCurrentMenu = () => {
    button.removeEventListener("click", onButtonClick);
    document.removeEventListener("click", onDocumentClick);
    document.removeEventListener("keydown", onKeydown);
    root.removeEventListener("focusout", onFocusout);
    root.remove();
  };
}
