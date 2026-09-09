import {
  listAdminProfiles,
  requireAdminAccess,
  setProfileActivationStatus,
  setProfileRole,
} from "./auth.js";
import { initAdminOrders } from "./adminOrders.js";
import { initAdminProducts } from "./adminProducts.js";

const ROLE_LABELS = {
  cliente: "Cliente",
  parceiro: "Parceiro",
  funcionario: "Funcionário",
  master: "Master",
};

const STATUS_LABELS = {
  pendente: "Pendente",
  ativo: "Ativo",
  bloqueado: "Bloqueado",
  inativo: "Inativo",
};

function renderAdminState(profile) {
  const roleLabel = document.querySelector("[data-admin-role]");
  if (roleLabel) {
    roleLabel.textContent = ROLE_LABELS[profile.papel] || profile.papel;
  }

  document.querySelectorAll("[data-master-only]").forEach((element) => {
    element.hidden = profile.papel !== "master";
  });
}

function profileTitle(profile) {
  return profile.nome_exibicao || profile.email_normalizado || profile.user_id;
}

function renderProfileCard(profile) {
  const card = document.createElement("article");
  card.className = "admin-card";

  const statusLabel = document.createElement("span");
  statusLabel.className = "card-kicker";
  statusLabel.textContent = STATUS_LABELS[profile.status_ativacao] || profile.status_ativacao;

  const title = document.createElement("h2");
  title.textContent = profileTitle(profile);

  const email = document.createElement("p");
  email.textContent = profile.email_normalizado || "Sem e-mail informado";

  const roleLabel = document.createElement("label");
  roleLabel.textContent = "Papel";

  const roleSelect = document.createElement("select");
  roleSelect.dataset.profileRole = profile.user_id;
  Object.entries(ROLE_LABELS).forEach(([role, label]) => {
    const option = document.createElement("option");
    option.value = role;
    option.textContent = label;
    option.selected = role === profile.papel;
    roleSelect.append(option);
  });

  const activationLabel = document.createElement("label");
  activationLabel.textContent = "Status";

  const activationSelect = document.createElement("select");
  activationSelect.dataset.profileStatus = profile.user_id;
  Object.entries(STATUS_LABELS).forEach(([status, label]) => {
    const option = document.createElement("option");
    option.value = status;
    option.textContent = label;
    option.selected = status === profile.status_ativacao;
    activationSelect.append(option);
  });

  const saveButton = document.createElement("button");
  saveButton.className = "button secondary";
  saveButton.type = "button";
  saveButton.dataset.profileSave = profile.user_id;
  saveButton.textContent = "Salvar perfil";

  card.append(
    statusLabel,
    title,
    email,
    roleLabel,
    roleSelect,
    activationLabel,
    activationSelect,
    saveButton,
  );

  return card;
}

async function loadMasterProfiles() {
  const container = document.querySelector("[data-admin-profiles]");
  if (!container) return;

  try {
    const profiles = await listAdminProfiles();
    container.replaceChildren(...profiles.map(renderProfileCard));

    container.querySelectorAll("[data-profile-save]").forEach((button) => {
      button.addEventListener("click", async () => {
        const userId = button.dataset.profileSave;
        const role = container.querySelector(`[data-profile-role="${userId}"]`)?.value;
        const status = container.querySelector(`[data-profile-status="${userId}"]`)?.value;
        const motivo = "Atualizacao administrativa pela Fase 3 do IAGO Shopping.";

        button.disabled = true;
        try {
          await setProfileRole(userId, role, motivo);
          await setProfileActivationStatus(userId, status, motivo);
          await loadMasterProfiles();
        } catch (error) {
          window.alert(error.message);
        } finally {
          button.disabled = false;
        }
      });
    });
  } catch (error) {
    container.textContent = error.message;
  }
}

export function initAdminPage() {
  const cards = document.querySelectorAll(".admin-card");
  cards.forEach((card) => {
    card.setAttribute("tabindex", "0");
  });

  requireAdminAccess()
    .then((authState) => {
      if (!authState) return;

      const { profile } = authState;
      renderAdminState(profile);
      initAdminProducts();
      initAdminOrders({ isMaster: profile.papel === "master" });
      if (profile.papel === "master") {
        loadMasterProfiles();
      }
    })
    .catch(() => {
      window.location.href = "/login/";
    });
}
