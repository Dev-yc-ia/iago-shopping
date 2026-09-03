# Pontos de Extensão da Fase 0 e Preparação Fase 1

## Backend

- `backend/config`: variáveis locais não sensíveis.
- `backend/routers`: novas rotas versionadas.
- `backend/schemas`: contratos Pydantic.
- `backend/services`: regras de negócio futuras.

## Frontend

- `frontend/config/products.js`: trocar mocks por dados vindos de API.
- `frontend/features/catalog.js`: conectar filtros reais.
- `frontend/features/product.js`: carregar detalhes persistidos.
- `frontend/features/login.js`: substituir intenção visual por autenticação real.
- `frontend/features/admin.js`: implementar painel conforme permissões.

## Dados

`sql/migrations` contém a migração revisável da Fase 1 para perfis, convites, auditoria e RLS.

`sql/bootstrap` contém o script controlado para definir o primeiro master depois que o usuário existir no Supabase Auth.

Nenhum script conecta ou altera Supabase automaticamente.
