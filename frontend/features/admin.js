import {
  decidePartnerApplication,
  listPartnerApplications,
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

const PARTNER_APPLICATION_STATUS_LABELS = {
  pendente: "Pendente",
  aprovado: "Aprovado",
  recusado: "Recusado",
};

function renderAdminState(profile) {
  const roleLabel = document.querySelector("[data-admin-role]");
  if (roleLabel) {
    roleLabel.textContent = ROLE_LABELS[profile.papel] || profile.papel;
  }

  document.querySelectorAll("[data-master-only]").forEach((element) => {
    element.hidden = profile.papel !== "master";
  });

  document.querySelectorAll("[data-admin-master-area]").forEach((element) => {
    element.hidden = profile.papel !== "master";
  });

  document.querySelectorAll("[data-admin-payments-area]").forEach((element) => {
    element.hidden = profile.papel === "parceiro";
  });

  const ordersTitle = document.querySelector("[data-admin-orders-area] h1");
  const ordersEyebrow = document.querySelector("[data-admin-orders-area] .eyebrow");
  if (ordersTitle && profile.papel === "parceiro") ordersTitle.textContent = "Meus pedidos";
  if (ordersEyebrow && profile.papel === "parceiro") ordersEyebrow.textContent = "Parceiro";
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

function renderPartnerApplicationCard(application, onDecision) {
  const card = document.createElement("article");
  card.className = "admin-card partner-application-card";

  const status = document.createElement("span");
  status.className = "card-kicker";
  status.textContent = PARTNER_APPLICATION_STATUS_LABELS[application.status] || application.status;

  const title = document.createElement("h2");
  title.textContent = application.nome || application.nome_loja || application.email_normalizado || "Solicitação de parceiro";

  const details = document.createElement("p");
  details.textContent = [
    application.email_normalizado || "Sem e-mail",
    application.tipo_pessoa || "PF/PJ",
    application.documento_normalizado || "Documento não informado",
  ].join(" | ");

  const terms = document.createElement("p");
  terms.className = "extension-note";
  terms.textContent = `Termos V${application.versao_termo} aceitos em ${new Date(application.aceito_em).toLocaleString("pt-BR")}.`;

  const approveButton = document.createElement("button");
  approveButton.className = "button primary";
  approveButton.type = "button";
  approveButton.textContent = "Aprovar";
  approveButton.disabled = application.status !== "pendente";
  approveButton.addEventListener("click", () => onDecision(application, "aprovado"));

  const rejectButton = document.createElement("button");
  rejectButton.className = "button ghost";
  rejectButton.type = "button";
  rejectButton.textContent = "Recusar";
  rejectButton.disabled = application.status !== "pendente";
  rejectButton.addEventListener("click", () => onDecision(application, "recusado"));

  card.append(status, title, details, terms, approveButton, rejectButton);
  return card;
}

async function loadPartnerApplications() {
  const container = document.querySelector("[data-partner-applications]");
  const feedback = document.querySelector("[data-partner-applications-feedback]");
  if (!container) return;

  async function decide(application, decision) {
    const defaultReason = decision === "aprovado"
      ? "Aprovação Master do cadastro de parceiro."
      : "";
    const reason = window.prompt(
      decision === "aprovado"
        ? "Motivo da aprovação"
        : "Motivo da recusa",
      defaultReason,
    );
    if (reason === null) return;

    try {
      await decidePartnerApplication(application.id, decision, reason);
      await loadPartnerApplications();
      await loadMasterProfiles();
    } catch (error) {
      window.alert(error.message);
    }
  }

  try {
    const applications = await listPartnerApplications();
    if (!applications.length) {
      container.innerHTML = '<p class="empty-state">Nenhuma solicitação de parceiro encontrada.</p>';
    } else {
      container.replaceChildren(...applications.map((application) => (
        renderPartnerApplicationCard(application, decide)
      )));
    }
    if (feedback) {
      feedback.textContent = `${applications.length} solicitação${applications.length === 1 ? "" : "ões"} encontrada${applications.length === 1 ? "" : "s"}.`;
    }
  } catch (error) {
    if (feedback) feedback.textContent = error.message;
  }
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
      if (profile.papel === "master") {
        initAdminProducts();
      }
      initAdminOrders({ role: profile.papel, isMaster: profile.papel === "master" });
      if (profile.papel === "master") {
        loadMasterProfiles();
        loadPartnerApplications();
      }
    })
    .catch(() => {
      window.location.href = "/login/";
    });
}
