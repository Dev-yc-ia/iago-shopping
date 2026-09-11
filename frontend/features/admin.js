import {
  decidePartnerApplication,
  getSupabaseClient,
  listPartnerApplications,
  listAdminProfiles,
  requireAdminAccess,
  setProfileActivationStatus,
  setProfileRole,
} from "./auth.js";
import { initAdminOrders, initAdminPayments } from "./adminOrders.js";
import { initAdminProductForm, initAdminProductsList } from "./adminProducts.js";

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

const ADMIN_NAV_COLLAPSED_STORAGE_KEY = "iago-shopping-admin-nav-collapsed";

const MODULES = {
  overview: {
    path: "/admin/",
    label: "Visão geral",
    title: "Visão geral",
    eyebrow: "Admin",
    roles: ["master", "funcionario", "parceiro"],
  },
  products: {
    path: "/admin/produtos/",
    label: "Produtos",
    partnerLabel: "Meus produtos",
    title: "Produtos",
    partnerTitle: "Meus produtos",
    eyebrow: "Cadastro",
    roles: ["master", "funcionario", "parceiro"],
  },
  productNew: {
    path: "/admin/produtos/novo/",
    label: "Novo produto",
    title: "Cadastrar produto",
    eyebrow: "Produtos",
    roles: ["master", "funcionario", "parceiro"],
  },
  productEdit: {
    path: "/admin/produtos/editar/",
    label: "Editar produto",
    title: "Editar produto",
    eyebrow: "Produtos",
    roles: ["master", "funcionario", "parceiro"],
    hiddenFromNav: true,
  },
  orders: {
    path: "/admin/pedidos/",
    label: "Pedidos",
    partnerLabel: "Meus pedidos",
    title: "Pedidos",
    partnerTitle: "Meus pedidos",
    eyebrow: "Operação",
    roles: ["master", "funcionario", "parceiro"],
  },
  deliveries: {
    path: "/admin/entregas/",
    label: "Entregas",
    partnerLabel: "Minhas entregas",
    title: "Entregas",
    partnerTitle: "Minhas entregas",
    eyebrow: "Fulfillment",
    roles: ["master", "funcionario", "parceiro"],
  },
  partners: {
    path: "/admin/parceiros/",
    label: "Parceiros",
    title: "Parceiros ativos",
    eyebrow: "Master",
    roles: ["master"],
  },
  applications: {
    path: "/admin/solicitacoes/",
    label: "Solicitações",
    title: "Solicitações de parceiros",
    eyebrow: "Master",
    roles: ["master"],
  },
  profiles: {
    path: "/admin/perfis/",
    label: "Perfis",
    title: "Perfis e permissões",
    eyebrow: "Master",
    roles: ["master"],
  },
  payments: {
    path: "/admin/pagamentos/",
    label: "Pagamentos",
    title: "Pagamentos",
    eyebrow: "Operação",
    roles: ["master", "funcionario"],
  },
};

function isMaster(profile) {
  return profile?.papel === "master";
}

function isPartner(profile) {
  return profile?.papel === "parceiro";
}

function moduleLabel(module, profile) {
  return isPartner(profile) && module.partnerLabel ? module.partnerLabel : module.label;
}

function moduleTitle(module, profile) {
  return isPartner(profile) && module.partnerTitle ? module.partnerTitle : module.title;
}

function routeKeyFromLocation() {
  const path = window.location.pathname.replace(/\/+$/, "/");
  if (path === "/admin/produtos/novo/") return "productNew";
  if (path === "/admin/produtos/editar/") return "productEdit";
  if (path === "/admin/produtos/") return "products";
  if (path === "/admin/pedidos/") return "orders";
  if (path === "/admin/entregas/") return "deliveries";
  if (path === "/admin/parceiros/") return "partners";
  if (path === "/admin/solicitacoes/") return "applications";
  if (path === "/admin/perfis/") return "profiles";
  if (path === "/admin/pagamentos/") return "payments";
  return "overview";
}

function canAccessModule(profile, key) {
  return MODULES[key]?.roles.includes(profile?.papel);
}

function visibleModules(profile) {
  return Object.entries(MODULES)
    .filter(([, module]) => !module.hiddenFromNav && module.roles.includes(profile.papel));
}

function profileTitle(profile) {
  return profile.nome_exibicao || profile.email_normalizado || profile.user_id;
}

function partnerTitle(profile) {
  return profile.nome_exibicao || profile.nome_completo || profile.email_normalizado || profile.user_id;
}

function readAdminNavCollapsed() {
  try {
    return window.localStorage.getItem(ADMIN_NAV_COLLAPSED_STORAGE_KEY) === "1";
  } catch {
    return false;
  }
}

function saveAdminNavCollapsed(collapsed) {
  try {
    window.localStorage.setItem(ADMIN_NAV_COLLAPSED_STORAGE_KEY, collapsed ? "1" : "0");
  } catch {
    // Local storage can be unavailable in restricted browser contexts.
  }
}

function createShell(profile, activeKey) {
  const activeModule = MODULES[activeKey] || MODULES.overview;
  const navCollapsed = readAdminNavCollapsed();
  const shell = document.createElement("section");
  shell.className = "admin-shell";
  shell.innerHTML = `
    <section class="section-head admin-page-head">
      <div>
        <span class="eyebrow">${activeModule.eyebrow}</span>
        <h1>${moduleTitle(activeModule, profile)}</h1>
      </div>
      <p>Perfil ativo: <span data-admin-role>${ROLE_LABELS[profile.papel] || profile.papel}</span></p>
    </section>

    <div class="admin-layout${navCollapsed ? " admin-nav-collapsed" : ""}" data-admin-layout>
      <nav class="admin-nav${navCollapsed ? " is-collapsed" : ""}" data-admin-nav aria-label="Navegação administrativa">
        <div class="admin-nav-head">
          <strong class="admin-nav-title">Telas</strong>
          <button
            class="button secondary admin-menu-toggle"
            type="button"
            data-admin-menu-toggle
            aria-expanded="${String(!navCollapsed)}"
            aria-label="${navCollapsed ? "Expandir menu admin" : "Recolher menu admin"}"
          >${navCollapsed ? ">>>" : "<<<"}</button>
        </div>
        <div class="admin-nav-body">
          ${visibleModules(profile).map(([key, module]) => `
            <a href="${module.path}" ${key === activeKey ? 'aria-current="page"' : ""}>
              ${moduleLabel(module, profile)}
            </a>
          `).join("")}
        </div>
      </nav>
      <div class="admin-module-surface" data-admin-module></div>
    </div>
  `;

  const layout = shell.querySelector("[data-admin-layout]");
  const toggle = shell.querySelector("[data-admin-menu-toggle]");
  const nav = shell.querySelector("[data-admin-nav]");

  function applyAdminNavState(collapsed) {
    layout?.classList.toggle("admin-nav-collapsed", collapsed);
    nav?.classList.toggle("is-collapsed", collapsed);
    saveAdminNavCollapsed(collapsed);

    if (toggle) {
      toggle.textContent = collapsed ? ">>>" : "<<<";
      toggle.setAttribute("aria-expanded", String(!collapsed));
      toggle.setAttribute("aria-label", collapsed ? "Expandir menu admin" : "Recolher menu admin");
    }
  }

  toggle?.addEventListener("click", () => {
    applyAdminNavState(!nav?.classList.contains("is-collapsed"));
  });

  return shell;
}

function quickCards(profile) {
  const entries = visibleModules(profile).filter(([key]) => key !== "overview");
  return `
    <section class="admin-overview-grid">
      ${entries.map(([, module]) => `
        <a class="admin-card admin-shortcut-card" href="${module.path}">
          <span class="card-kicker">${module.eyebrow}</span>
          <h2>${moduleLabel(module, profile)}</h2>
          <p>${shortcutCopy(module, profile)}</p>
        </a>
      `).join("")}
    </section>
  `;
}

function shortcutCopy(module, profile) {
  if (module.path.includes("/produtos/") && isPartner(profile)) return "Cadastrar e revisar seus próprios produtos.";
  if (module.path.includes("/produtos/")) return "Listar produtos, editar cadastro e abrir novo item.";
  if (module.path.includes("/pedidos/") && isPartner(profile)) return "Acompanhar pedidos pagos dos seus produtos.";
  if (module.path.includes("/pedidos/")) return "Acompanhar pedidos recebidos e cancelamentos permitidos.";
  if (module.path.includes("/entregas/") && isPartner(profile)) return "Confirmar envio ou entrega pessoal.";
  if (module.path.includes("/entregas/")) return "Acompanhar cumprimento por parceiro.";
  if (module.path.includes("/solicitacoes/")) return "Aprovar ou recusar candidatos a parceiro.";
  if (module.path.includes("/perfis/")) return "Gerir papéis e status de acesso.";
  if (module.path.includes("/pagamentos/")) return "Consultar pagamentos reais da operação.";
  return "Abrir módulo.";
}

function renderOverview(profile) {
  const surface = document.querySelector("[data-admin-module]");
  if (!surface) return;
  surface.innerHTML = `
    <section class="admin-home">
      ${quickCards(profile)}
    </section>
  `;
}

function renderProductsList(profile) {
  const surface = document.querySelector("[data-admin-module]");
  if (!surface) return;
  surface.innerHTML = `
    <section class="admin-module-head" data-admin-master-area>
      <div>
        <span class="eyebrow">Produtos</span>
        <h2>${isPartner(profile) ? "Meus produtos" : "Lista de produtos"}</h2>
      </div>
      <a class="button primary" href="/admin/produtos/novo/">Novo produto</a>
    </section>
    <p class="admin-feedback" data-product-feedback>Carregando produtos.</p>
    <section class="admin-grid admin-products-grid" data-products-list></section>
  `;
  initAdminProductsList({ profile });
}

function renderProductForm(profile) {
  const surface = document.querySelector("[data-admin-module]");
  if (!surface) return;
  surface.innerHTML = `
    <section class="admin-module-head">
      <div>
        <span class="eyebrow">Produto</span>
        <h2>${routeKeyFromLocation() === "productEdit" ? "Editar cadastro" : "Novo cadastro"}</h2>
      </div>
      <a class="button secondary" href="/admin/produtos/">Voltar para produtos</a>
    </section>
    <p class="admin-feedback" data-product-feedback>Carregando produto.</p>
    <section class="admin-product-editor-layout">
      <form class="product-form admin-product-editor" data-product-form>
        <input type="hidden" name="id">
        <input type="hidden" name="sku">
        <div class="sku-status" data-product-sku-display>SKU gerado automaticamente ao salvar</div>

        <section class="admin-form-section">
          <span class="card-kicker">Informações principais</span>
          <div class="admin-form-grid">
            <label data-admin-field for="product-name">Nome
              <input id="product-name" name="nome" type="text" placeholder="Nome do produto" required>
            </label>
            <label data-admin-field for="product-brand">Marca
              <input id="product-brand" name="marca" type="text" placeholder="Marca" required>
            </label>
            <label data-admin-field for="product-category">Categoria
              <select id="product-category" name="categoria">
                <option value="shapes">Shapes</option>
                <option value="rodas">Rodas</option>
                <option value="tenis">Tênis</option>
                <option value="roupas-camisas">Roupas e camisas</option>
                <option value="cameras-acessorios">Câmeras e acessórios</option>
              </select>
            </label>
            <label data-admin-field for="product-status">Status
              <select id="product-status" name="status">
                <option value="rascunho">Rascunho</option>
                <option value="publicado">Publicado</option>
                <option value="arquivado">Arquivado</option>
              </select>
            </label>
          </div>
        </section>

        <section class="admin-form-section">
          <span class="card-kicker">Comercial</span>
          <div class="admin-form-grid">
            <label data-admin-field for="product-price">Preço final
              <input id="product-price" name="preco" type="number" min="0" step="0.01" placeholder="0.00" required>
            </label>
            <label data-admin-field for="product-partner">Parceiro responsável
              <select id="product-partner" name="parceiroUserId" data-product-partner>
                <option value="">Selecione um parceiro ativo</option>
              </select>
            </label>
            <label data-admin-field for="product-partner-payout">Repasse ao parceiro
              <input id="product-partner-payout" name="valorRepasseParceiro" type="number" min="0" step="0.01" placeholder="0.00">
            </label>
            <div class="sku-status" data-product-margin-preview>Margem IAGO: R$ 0,00</div>
          </div>
        </section>

        <section class="admin-form-section admin-form-section--wide">
          <label for="product-description">
            <span class="card-kicker">Descrição</span>
            <textarea id="product-description" name="descricao" rows="8" placeholder="Descrição comercial"></textarea>
          </label>
        </section>

        <section class="admin-form-section">
          <fieldset class="variation-editor">
            <legend>Variações e estoque</legend>
            <div class="variation-editor__head">
              <span>Tamanho/Variação</span>
              <span>Estoque</span>
              <span>Remover</span>
            </div>
            <div class="variation-editor__rows" data-variation-rows></div>
            <button class="button secondary variation-editor__add" type="button" data-variation-add>+ Adicionar variação</button>
          </fieldset>
        </section>

        <section class="admin-form-section">
          <span class="card-kicker">Fotos</span>
          <label for="product-photos">Fotos do produto</label>
          <input id="product-photos" name="fotosProduto" type="file" accept="image/*" multiple>
          <div data-product-image-preview></div>
        </section>

        <section class="admin-form-section admin-product-actions">
          <button class="button ghost" type="button" data-product-reset>Limpar</button>
          <button class="button primary" type="submit">Salvar produto</button>
        </section>
      </form>

      <aside class="admin-form-preview">
        <span class="card-kicker">Preview</span>
        <article class="product-card product-live-preview" data-product-live-preview aria-live="polite">
          <div data-preview-visual></div>
          <div class="product-body">
            <span class="card-kicker" data-preview-status>Rascunho</span>
            <h3 data-preview-name>Nome do produto</h3>
            <p class="product-description-preview" data-preview-description>Descrição comercial</p>
            <div class="product-meta">
              <span data-preview-brand>Marca</span>
              <strong data-preview-price>R$ 0,00</strong>
            </div>
            <div class="status-row">
              <span data-preview-availability>Disponível</span>
              <span data-preview-stock>0 unidades</span>
            </div>
            <span class="button secondary card-link" data-preview-category>Shapes</span>
          </div>
        </article>
      </aside>
    </section>
  `;
  initAdminProductForm({ profile });
}

function renderOrders(profile) {
  const surface = document.querySelector("[data-admin-module]");
  if (!surface) return;
  surface.innerHTML = `
    <section class="admin-module-head">
      <div>
        <span class="eyebrow">Pedidos</span>
        <h2>${isPartner(profile) ? "Meus pedidos" : "Pedidos recebidos"}</h2>
      </div>
    </section>
    <p class="admin-feedback" data-admin-orders-feedback>Carregando pedidos.</p>
    <section class="admin-filter-row" aria-label="Filtros de pedidos">
      <button class="button secondary" type="button">Todos</button>
      <button class="button ghost" type="button">Pendentes</button>
      <button class="button ghost" type="button">Pagos</button>
      <button class="button ghost" type="button">Concluídos</button>
    </section>
    <section class="admin-grid" data-admin-orders></section>
  `;
  initAdminOrders({ role: profile.papel, isMaster: profile.papel === "master" });
}

function renderDeliveries(profile) {
  const surface = document.querySelector("[data-admin-module]");
  if (!surface) return;
  surface.innerHTML = `
    <section class="admin-module-head">
      <div>
        <span class="eyebrow">Entregas</span>
        <h2>${isPartner(profile) ? "Minhas entregas" : "Entregas por parceiro"}</h2>
      </div>
    </section>
    <p class="admin-feedback" data-admin-deliveries-feedback>Carregando entregas.</p>
    <section class="admin-filter-row" aria-label="Filtros de entregas">
      <button class="button secondary" type="button">Aguardando ação</button>
      <button class="button ghost" type="button">Enviadas</button>
      <button class="button ghost" type="button">Entrega pessoal</button>
      <button class="button ghost" type="button">Aguardando cliente</button>
      <button class="button ghost" type="button">Concluídas</button>
    </section>
    <section class="admin-grid" data-admin-deliveries></section>
  `;
  initAdminOrders({ role: profile.papel, isMaster: profile.papel === "master", module: "deliveries" });
}

function renderProfiles() {
  const surface = document.querySelector("[data-admin-module]");
  if (!surface) return;
  surface.innerHTML = `
    <section class="admin-module-head" data-master-only>
      <div>
        <span class="eyebrow">Master</span>
        <h2>Perfis e permissões</h2>
      </div>
    </section>
    <section class="admin-grid" data-admin-profiles data-master-only></section>
  `;
  loadMasterProfiles();
}

function renderApplications() {
  const surface = document.querySelector("[data-admin-module]");
  if (!surface) return;
  surface.innerHTML = `
    <section class="admin-module-head" data-master-only>
      <div>
        <span class="eyebrow">Master</span>
        <h2>Solicitações de parceiros</h2>
      </div>
    </section>
    <p class="admin-feedback" data-partner-applications-feedback>Carregando solicitações.</p>
    <section class="admin-grid" data-partner-applications data-master-only></section>
  `;
  loadPartnerApplications();
}

function renderPayments() {
  const surface = document.querySelector("[data-admin-module]");
  if (!surface) return;
  surface.innerHTML = `
    <section class="admin-module-head" data-admin-payments-area>
      <div>
        <span class="eyebrow">Pagamentos</span>
        <h2>Pagamentos reais</h2>
      </div>
    </section>
    <p class="admin-feedback" data-admin-payments-feedback>Carregando pagamentos.</p>
    <section class="admin-grid" data-admin-payments data-admin-payments-area></section>
  `;
  initAdminPayments();
}

function renderDenied(profile, key) {
  const surface = document.querySelector("[data-admin-module]");
  if (!surface) return;
  surface.innerHTML = `
    <article class="notice-panel">
      <span class="card-kicker">Sem permissão</span>
      <h2>Acesso restrito</h2>
      <p>Seu perfil ${ROLE_LABELS[profile.papel] || profile.papel} não acessa este módulo.</p>
      <a class="button secondary" href="/admin/">Voltar para visão geral</a>
    </article>
  `;
  console.warn(`Acesso negado ao módulo admin ${key}. A proteção de dados permanece nas RPCs/RLS.`);
}

async function listActivePartners() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_admin_listar_parceiros_ativos");
  if (error) throw error;
  return data || [];
}

function renderPartnerCard(profile) {
  const card = document.createElement("article");
  card.className = "admin-card";

  const status = document.createElement("span");
  status.className = "card-kicker";
  status.textContent = STATUS_LABELS[profile.status_ativacao] || profile.status_ativacao;

  const title = document.createElement("h2");
  title.textContent = partnerTitle(profile);

  const email = document.createElement("p");
  email.textContent = profile.email_normalizado || "Sem e-mail informado";

  const phone = document.createElement("p");
  phone.className = "extension-note";
  phone.textContent = profile.telefone_normalizado || "Telefone não informado";

  card.append(status, title, email, phone);
  return card;
}

async function renderPartners() {
  const surface = document.querySelector("[data-admin-module]");
  if (!surface) return;
  surface.innerHTML = `
    <section class="admin-module-head" data-master-only>
      <div>
        <span class="eyebrow">Master</span>
        <h2>Parceiros ativos</h2>
      </div>
    </section>
    <p class="admin-feedback" data-admin-partners-feedback>Carregando parceiros.</p>
    <section class="admin-grid" data-admin-partners data-master-only></section>
  `;

  const container = surface.querySelector("[data-admin-partners]");
  const feedback = surface.querySelector("[data-admin-partners-feedback]");
  try {
    const partners = await listActivePartners();
    if (feedback) feedback.textContent = `${partners.length} parceiro${partners.length === 1 ? "" : "s"} ativo${partners.length === 1 ? "" : "s"}.`;
    if (!partners.length) {
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.textContent = "Nenhum parceiro ativo encontrado.";
      container.replaceChildren(empty);
      return;
    }
    container.replaceChildren(...partners.map(renderPartnerCard));
  } catch (error) {
    if (feedback) feedback.textContent = error.message;
  }
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

  card.append(statusLabel, title, email, roleLabel, roleSelect, activationLabel, activationSelect, saveButton);
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
      decision === "aprovado" ? "Motivo da aprovação" : "Motivo da recusa",
      defaultReason,
    );
    if (reason === null) return;

    try {
      await decidePartnerApplication(application.id, decision, reason);
      await loadPartnerApplications();
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
        const motivo = "Atualizacao administrativa pelo Admin modular WEB-13.";

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

function mountModule(profile, key) {
  if (!canAccessModule(profile, key)) {
    renderDenied(profile, key);
    return;
  }

  if (key === "overview") renderOverview(profile);
  if (key === "products") renderProductsList(profile);
  if (key === "productNew" || key === "productEdit") renderProductForm(profile);
  if (key === "orders") renderOrders(profile);
  if (key === "deliveries") renderDeliveries(profile);
  if (key === "partners" && isMaster(profile)) renderPartners();
  if (key === "applications" && profile.papel === "master") renderApplications();
  if (key === "profiles" && profile.papel === "master") renderProfiles();
  if (key === "payments") renderPayments();
}

export function initAdminPage() {
  const main = document.querySelector(".page-main");
  const activeKey = routeKeyFromLocation();

  requireAdminAccess()
    .then((authState) => {
      if (!authState) return;

      const { profile } = authState;
      main.replaceChildren(createShell(profile, activeKey));
      mountModule(profile, activeKey);
    })
    .catch(() => {
      window.location.href = "/login/";
    });
}
