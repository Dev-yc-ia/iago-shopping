const REQUIRED_FIELD_LABELS = {
  nomeCompleto: "Nome completo",
  email: "E-mail",
  telefone: "Telefone / WhatsApp",
  nomeDestinatario: "Nome do destinatario",
  cep: "CEP",
  logradouro: "Logradouro",
  numero: "Numero",
  bairro: "Bairro",
  cidade: "Cidade",
  uf: "UF",
};

export const CHECKOUT_REQUIRED_FIELDS = Object.keys(REQUIRED_FIELD_LABELS);
export const CHECKOUT_REQUIRED_FIELD_LABELS = { ...REQUIRED_FIELD_LABELS };

export function onlyDigits(value) {
  return String(value || "").replace(/\D/g, "");
}

function hasText(value) {
  return String(value || "").trim() !== "";
}

function hasUsablePhone(value) {
  const digits = onlyDigits(value);
  return digits.length >= 10 && /[1-9]/.test(digits);
}

function hasValidZip(value) {
  return onlyDigits(value).length === 8;
}

function hasValidState(value) {
  return /^[A-Z]{2}$/.test(String(value || "").trim().toUpperCase());
}

function valueFrom(profile, address, session, field) {
  const sessionEmail = session?.user?.email || "";
  const values = {
    nomeCompleto: profile?.nome_completo,
    email: profile?.email_normalizado || sessionEmail,
    telefone: profile?.telefone_normalizado,
    nomeDestinatario: address?.nome_destinatario,
    cep: address?.cep,
    logradouro: address?.logradouro,
    numero: address?.numero,
    bairro: address?.bairro,
    cidade: address?.cidade,
    uf: address?.uf,
  };
  return values[field];
}

function isFieldComplete(profile, address, session, field) {
  const value = valueFrom(profile, address, session, field);
  if (field === "telefone") return hasUsablePhone(value);
  if (field === "cep") return hasValidZip(value);
  if (field === "uf") return hasValidState(value);
  return hasText(value);
}

export function validateCheckoutProfile(profile = {}, address = {}, session = null) {
  const missingFields = CHECKOUT_REQUIRED_FIELDS.filter((field) => (
    !isFieldComplete(profile, address, session, field)
  ));

  return {
    complete: missingFields.length === 0,
    missingFields,
  };
}
