# IAGO Shopping

Fase 0 local do IAGO Shopping, criada sobre o projeto existente.

Esta fase entrega uma fundação visual e técnica mínima:

- frontend puro em HTML/CSS/JS, com caminhos relativos e pronto para GitHub Pages;
- tema único escuro, fixo, inspirado na identidade do Hub Operacional IAGO;
- tipografia institucional Ethnocentric RG em marca, títulos curtos e ações;
- entrada/onboarding obrigatória antes do catálogo, com opção clara de continuar sem login;
- catálogo demonstrativo responsivo com filtros e produtos mock;
- página de produto com atributos modulares por categoria;
- tela de login e admin apenas estruturais;
- FastAPI mínimo para `/health`, `/api/health` e documentação em `/docs`;
- scripts Windows para instalar, iniciar e testar sem digitar `activate`.

## Como Rodar

No Windows, use os atalhos na raiz do projeto:

1. `instalar.bat`
2. `iniciar.bat`

O `iniciar.bat` usa sempre `127.0.0.1:8010`, encerra apenas processos que estejam escutando essa porta, sobe o backend, aguarda `/health` responder e abre o IAGO Shopping automaticamente no Chrome quando ele estiver instalado. Para evitar cache visual entre execuções, o Chrome é aberto com um perfil temporário isolado em `%TEMP%\IAGO_Shopping_Chrome_Profile_8010`, removido e recriado somente para o Shopping. Se uma janela antiga do Chrome ainda estiver usando esse perfil, o script não encerra o navegador: ele cria um perfil limpo com o mesmo prefixo para a execução atual. Se o Chrome não for encontrado nos locais padrão, o script abre `http://127.0.0.1:8010` no navegador padrão.

O script não altera a porta `8000` e não interfere no Hub Operacional IAGO.

Para verificar:

```bat
testar.bat
```

O frontend também pode ser aberto diretamente por `frontend/index.html`, pois usa caminhos relativos. A página inicial é a entrada; o catálogo público fica em `frontend/catalogo.html`.

## Estrutura

```text
backend/
  config/      Configurações locais não sensíveis
  routers/     Rotas FastAPI
  schemas/     Contratos de resposta
  services/    Ponto futuro para regras de negócio
frontend/
  assets/      Logos e imagens
  config/      Dados mock e configuração visual
  core/        Inicialização da aplicação
  features/    Catálogo, produto, login e admin
  ui/          Componentes de interface
  utils/       Formatação e eventos anônimos locais
Documentos/    Planejamento e decisões
sql/migrations Reservado para migrações futuras
tests/         Verificações automatizadas
```

## Escopo da Fase 0

Incluído:

- catálogo público demonstrativo;
- filtros por busca, categoria e disponibilidade;
- categorias mock: shapes, rodas, tênis e roupas/camisas;
- atributos específicos por categoria:
  - shape: largura em polegadas;
  - roda: diâmetro em mm;
  - tênis: numeração;
  - roupa/camisa: tamanho de roupa por medida;
- registro local de eventos anônimos básicos em `localStorage`: entrada, continuar sem login, início de login e visualização de produto;
- pasta `frontend/assets/images/hero` com a imagem institucional `tela_login.png` da tela inicial.

Fora do escopo nesta fase:

- Supabase;
- autenticação real;
- banco de dados;
- upload;
- permissões;
- pagamento;
- estoque persistido;
- módulos funcionais do Hub como terminal, mapa, SQL View ou pipelines.

## Imagem da Tela Inicial

A pasta abaixo já existe:

```text
frontend/assets/images/hero
```

Imagem institucional usada pelo onboarding:

```text
tela_login.png
```

Origem restaurada: `C:\Users\Administrador\Documents\IAGO_CHAT\Logos\6- Mockup\Aplicação.png`.

Enquanto a imagem não existir, a tela usa fallback escuro com overlay navy e destaque cyan.

## Tipografia

A fonte institucional usada localmente é `frontend/assets/fonts/ethnocentric-rg.otf`.

Origem: `C:\Users\Administrador\Documents\IAGO_CHAT\Logos\5- Cor e Fonte Manual Basico\Ethnocentric Rg\ethnocentric rg.otf`.

Ela é aplicada somente em marca, títulos curtos, botões, eyebrows e tabs. Parágrafos, campos e links comuns continuam usando Segoe UI/sans-serif do sistema para preservar legibilidade.

## Configuração

`.env.example` contém apenas exemplos não sensíveis. Segredos reais devem ficar em `.env`, que está no `.gitignore`.

## Preparação Fase 1

A Fase 1 foi preparada como artefatos SQL/documentação revisáveis. Este projeto não conecta nem altera o Supabase de produção automaticamente.

Arquivos:

- `sql/migrations/20260827_001_fase1_perfis_convites_rls.sql`
- `sql/bootstrap/bootstrap_primeiro_master.sql`
- `Documentos/fase1_bootstrap_supabase.md`

O Shopping é separado da Pesquisa e guarda somente `response_id` como referência lógica. Não copiar respostas individuais da Pesquisa.

Para bootstrap do primeiro master, o usuário precisa informar:

- UUID da conta já criada em `auth.users.id`;
- e-mail normalizado dessa conta;
- nome de exibição.

O primeiro master deve ser definido somente via SQL Editor depois que o usuário existir no Supabase Auth. Senhas ficam somente no Supabase Auth.

## Verificações Esperadas

- `py -m compileall backend tests`
- `py -m pytest`
- abertura local em `http://127.0.0.1:8010`
- health em `http://127.0.0.1:8010/health`
- health alternativo em `http://127.0.0.1:8010/api/health`
- documentação em `http://127.0.0.1:8010/docs`
- catálogo público em `http://127.0.0.1:8010/catalogo.html`
