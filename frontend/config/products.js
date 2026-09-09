import { getSupabaseClient } from "../features/auth.js";

export const CATEGORIES = [
  { id: "todos", label: "Todos" },
  { id: "shapes", label: "Shapes" },
  { id: "rodas", label: "Rodas" },
  { id: "tenis", label: "Tênis" },
  { id: "roupas-camisas", label: "Roupas e camisas" },
  { id: "cameras-acessorios", label: "Câmeras e acessórios" },
];

export const CATALOG_SOURCE = "supabase";

export const PRODUCTS = [
  {
    id: "shape-maple-825",
    name: "Shape Maple IAGO 8.25",
    brand: "IAGO Skate",
    category: "shapes",
    price: 329.9,
    availability: "disponivel",
    stock: 7,
    highlight: "Concave médio, 7 lâminas",
    description: "Shape demonstrativo para validar atributos técnicos por largura.",
    attributes: [
      { label: "Largura", value: "8.25 pol" },
      { label: "Comprimento", value: "31.8 pol" },
      { label: "Construção", value: "Maple 7 lâminas" },
    ],
  },
  {
    id: "roda-street-54",
    name: "Roda Street Cyan 54 mm",
    brand: "IAGO Parts",
    category: "rodas",
    price: 189.9,
    availability: "disponivel",
    stock: 12,
    highlight: "Dureza 99A",
    description: "Roda mock com variação por diâmetro, sem tamanho genérico.",
    attributes: [
      { label: "Diâmetro", value: "54 mm" },
      { label: "Dureza", value: "99A" },
      { label: "Perfil", value: "Street" },
    ],
  },
  {
    id: "tenis-couro-40",
    name: "Tênis Session Preto",
    brand: "IAGO Wear",
    category: "tenis",
    price: 279.9,
    availability: "esgotado",
    stock: 0,
    highlight: "Numeração BR 40",
    description: "Produto esgotado para demonstrar interesse futuro e estoque por variação.",
    attributes: [
      { label: "Numeração", value: "40 BR" },
      { label: "Material", value: "Camurça e couro" },
      { label: "Solado", value: "Borracha vulcanizada" },
    ],
  },
  {
    id: "camisa-box-42",
    name: "Camisa Box Logo Manga Curta",
    brand: "IAGO Wear",
    category: "roupas-camisas",
    price: 119.9,
    availability: "disponivel",
    stock: 18,
    highlight: "Tamanho 42",
    description: "Camisa mock com grade por medida, sem tamanho universal.",
    attributes: [
      { label: "Tamanho de roupa", value: "42" },
      { label: "Tórax", value: "104 cm" },
      { label: "Comprimento", value: "72 cm" },
    ],
  },
  {
    id: "shape-cruiser-775",
    name: "Shape Cruiser 7.75",
    brand: "Parceiro Demo",
    category: "shapes",
    price: 299.9,
    availability: "disponivel",
    stock: 4,
    highlight: "Base leve",
    description: "Segundo shape para validar filtros e listagem responsiva.",
    attributes: [
      { label: "Largura", value: "7.75 pol" },
      { label: "Comprimento", value: "31.2 pol" },
      { label: "Construção", value: "Maple canadense" },
    ],
  },
  {
    id: "tenis-canvas-38",
    name: "Tênis Canvas Cyan",
    brand: "Parceiro Demo",
    category: "tenis",
    price: 239.9,
    availability: "disponivel",
    stock: 5,
    highlight: "Numeração BR 38",
    description: "Tênis mock para confirmar atributos específicos da categoria.",
    attributes: [
      { label: "Numeração", value: "38 BR" },
      { label: "Material", value: "Canvas reforçado" },
      { label: "Palmilha", value: "EVA removível" },
    ],
  },
  {
    id: "roda-park-56",
    name: "Roda Park Branco 56 mm",
    brand: "IAGO Parts",
    category: "rodas",
    price: 199.9,
    availability: "disponivel",
    stock: 9,
    highlight: "Dureza 97A",
    description: "Roda mock para transição entre park e bowl.",
    attributes: [
      { label: "Diâmetro", value: "56 mm" },
      { label: "Dureza", value: "97A" },
      { label: "Perfil", value: "Park" },
    ],
  },
  {
    id: "camisa-dry-44",
    name: "Camisa Dry IAGO",
    brand: "IAGO Wear",
    category: "roupas-camisas",
    price: 139.9,
    availability: "disponivel",
    stock: 11,
    highlight: "Tamanho 44",
    description: "Camisa mock com tecido leve e medida por grade.",
    attributes: [
      { label: "Tamanho de roupa", value: "44" },
      { label: "Tórax", value: "110 cm" },
      { label: "Tecido", value: "Dry fit" },
    ],
  },
  {
    id: "shape-pro-850",
    name: "Shape Pro Street 8.50",
    brand: "Parceiro Demo",
    category: "shapes",
    price: 349.9,
    availability: "esgotado",
    stock: 0,
    highlight: "Concave alto",
    description: "Shape mock esgotado para validar filtro de disponibilidade.",
    attributes: [
      { label: "Largura", value: "8.50 pol" },
      { label: "Comprimento", value: "32.1 pol" },
      { label: "Construção", value: "Maple 7 lâminas" },
    ],
  },
  {
    id: "tenis-session-41",
    name: "Tênis Session Natural",
    brand: "IAGO Wear",
    category: "tenis",
    price: 289.9,
    availability: "disponivel",
    stock: 6,
    highlight: "Numeração BR 41",
    description: "Tênis mock com grade real por numeração brasileira.",
    attributes: [
      { label: "Numeração", value: "41 BR" },
      { label: "Material", value: "Camurça" },
      { label: "Solado", value: "Borracha vulcanizada" },
    ],
  },
  {
    id: "roda-street-52",
    name: "Roda Street Preta 52 mm",
    brand: "Parceiro Demo",
    category: "rodas",
    price: 179.9,
    availability: "disponivel",
    stock: 14,
    highlight: "Dureza 101A",
    description: "Roda mock mais técnica para street.",
    attributes: [
      { label: "Diâmetro", value: "52 mm" },
      { label: "Dureza", value: "101A" },
      { label: "Perfil", value: "Street técnico" },
    ],
  },
  {
    id: "camisa-pesada-40",
    name: "Camisa Malha Pesada",
    brand: "Parceiro Demo",
    category: "roupas-camisas",
    price: 129.9,
    availability: "esgotado",
    stock: 0,
    highlight: "Tamanho 40",
    description: "Camisa mock esgotada para navegação e detalhe.",
    attributes: [
      { label: "Tamanho de roupa", value: "40" },
      { label: "Tórax", value: "100 cm" },
      { label: "Tecido", value: "Algodão pesado" },
    ],
  },
];

function firstImageUrl(images = []) {
  const primary = images.find((image) => image.principal);
  return primary?.url || images[0]?.url || "";
}

function normalizeVariation(variation = {}) {
  const stock = Number(variation.estoque_atual || variation.estoque || 0);
  return {
    id: variation.id || null,
    sku: variation.sku_variacao || "",
    name: variation.nome_variacao || variation.valor || variation.tamanho || "",
    stock,
    available: variation.ativo !== false && stock > 0,
    primary: Boolean(variation.principal),
  };
}

function normalizeCatalogProduct(product) {
  const variations = Array.isArray(product.variacoes)
    ? product.variacoes.map(normalizeVariation).filter((variation) => variation.name)
    : [];
  const stock = variations.length
    ? variations.reduce((total, variation) => total + (variation.available ? variation.stock : 0), 0)
    : Number(product.quantidade_estoque || 0);
  const images = Array.isArray(product.imagens) ? product.imagens : [];
  return {
    id: product.id,
    name: product.nome,
    brand: product.marca,
    category: product.categoria,
    price: Number(product.preco || 0),
    availability: stock > 0 ? "disponivel" : "esgotado",
    stock,
    variations,
    availableVariations: variations.filter((variation) => variation.available),
    highlight: product.destaque || product.descricao || "Produto publicado no IAGO Shopping.",
    description: product.descricao || "",
    attributes: Array.isArray(product.atributos) ? product.atributos : [],
    images,
    imageUrl: firstImageUrl(images),
  };
}

function summarizeByStatus(products = []) {
  return products.reduce((summary, product) => {
    const status = product.status || "sem_status";
    summary[status] = (summary[status] || 0) + 1;
    return summary;
  }, {});
}

function productSummary(product) {
  return {
    id: product.id,
    sku: product.sku,
    nome: product.nome,
    status: product.status,
  };
}

async function fetchCatalogDiagnostics(supabase) {
  const [productsResult, imagesResult, variationsResult] = await Promise.all([
    supabase
      .from("shopping_produtos")
      .select("id,sku,nome,status", { count: "exact" }),
    supabase
      .from("shopping_produto_imagens")
      .select("produto_id,principal"),
    supabase
      .from("shopping_produto_variacoes")
      .select("produto_id,ativo"),
  ]);

  return {
    productsResult,
    imagesResult,
    variationsResult,
  };
}

async function logCatalogDiagnostics(supabase, rpcProducts = []) {
  try {
    const { productsResult, imagesResult, variationsResult } = await fetchCatalogDiagnostics(supabase);
    const visibleProducts = productsResult.data || [];
    const visiblePublishedProducts = visibleProducts.filter((product) => product.status === "publicado");
    const rpcProductIds = new Set(rpcProducts.map((product) => product.id));
    const productsOutsideRpc = visibleProducts.filter((product) => !rpcProductIds.has(product.id));
    const principalImageProductIds = new Set((imagesResult.data || [])
      .filter((image) => image.principal)
      .map((image) => image.produto_id));
    const activeVariationProductIds = new Set((variationsResult.data || [])
      .filter((variation) => variation.ativo)
      .map((variation) => variation.produto_id));

    console.groupCollapsed("[IAGO Shopping] Diagnóstico do catálogo");
    console.info("RPC shopping_catalogo_produtos_publicados_com_estoque", {
      quantidade: rpcProducts.length,
      produtos: rpcProducts.map(productSummary),
    });
    console.info("shopping_produtos visíveis para o usuário atual", {
      quantidade: productsResult.count ?? visibleProducts.length,
      porStatus: summarizeByStatus(visibleProducts),
      erro: productsResult.error?.message || null,
    });
    console.info("Produtos publicados visíveis fora da RPC", productsOutsideRpc
      .filter((product) => product.status === "publicado")
      .map(productSummary));
    console.info("Produtos visíveis fora da RPC por status", {
      quantidade: productsOutsideRpc.length,
      porStatus: summarizeByStatus(productsOutsideRpc),
      produtos: productsOutsideRpc.map(productSummary),
    });
    console.info("Produtos publicados sem imagem principal", visiblePublishedProducts
      .filter((product) => !principalImageProductIds.has(product.id))
      .map(productSummary));
    console.info("Produtos publicados sem variação ativa", visiblePublishedProducts
      .filter((product) => !activeVariationProductIds.has(product.id))
      .map(productSummary));
    if (imagesResult.error) console.warn("Não foi possível ler imagens para diagnóstico.", imagesResult.error.message);
    if (variationsResult.error) console.warn("Não foi possível ler variações para diagnóstico.", variationsResult.error.message);
    console.groupEnd();
  } catch (error) {
    console.warn("Não foi possível executar o diagnóstico do catálogo.", error.message);
  }
}

export async function getCatalogProducts() {
  try {
    const supabase = await getSupabaseClient();
    const { data, error } = await supabase.rpc("shopping_catalogo_produtos_publicados_com_estoque");
    if (error) throw error;
    await logCatalogDiagnostics(supabase, data || []);
    return (data || []).map(normalizeCatalogProduct);
  } catch (error) {
    console.warn("Catálogo Supabase indisponível. Nenhum produto mock será exibido.", error.message);
    return CATALOG_SOURCE === "mock" ? PRODUCTS : [];
  }
}
