# Planejamento IAGO Shopping MVP

## Direção do Produto

O IAGO Shopping deve evoluir como vitrine e operação de e-commerce conectada ao ecossistema IAGO, começando por uma experiência pública opcionalmente sem login e avançando para contas, permissões, estoque real e dashboards.

## Decisões Consolidadas

- A pesquisa inicial será usada como origem de convites futuros.
- O catálogo público pode ser acessado sem login.
- A entrada deve sempre deixar clara a opção "Continuar sem login".
- As permissões futuras serão separadas em master, funcionário e parceiro.
- O estoque deve ser exato por variação, não apenas por produto genérico.
- Produtos esgotados devem permitir manifestação de interesse em fase futura.
- Dashboards futuros devem apoiar operação, catálogo, vendas, interesse em esgotados e desempenho por parceiro.

## Fase 0

Objetivo: criar uma fundação local, visual e extensível.

Entregas:

- FastAPI mínimo com health e documentação automática.
- Frontend independente com HTML, CSS e JavaScript modular.
- Identidade visual IAGO com tema escuro fixo, navy/quase-preto, accent cyan `#19DDDA`, bordas e glow discretos, fonte Segoe UI e logo branca.
- Marca exibindo a imagem IAGO seguida do texto "Shopping".
- Onboarding/login-first com imagem institucional, overlay navy e cartão glass escuro.
- Catálogo mock responsivo.
- Página de produto com atributos modulares por categoria.
- Login e admin apenas estruturais.
- Eventos anônimos locais sem dados pessoais.
- Scripts Windows para instalar, iniciar e testar sem ativação manual de ambiente.

Fora da Fase 0:

- Supabase.
- Autenticação real.
- Banco persistente.
- Upload.
- Permissões reais.
- Pagamento.
- Integrações externas.
- Cópia de módulos funcionais do Hub Operacional IAGO.

## Categorias e Atributos

As categorias mock iniciais são:

- Shapes: largura em polegadas, comprimento e construção.
- Rodas: diâmetro em mm, dureza e perfil.
- Tênis: numeração, material e solado.
- Roupas/camisas: tamanho de roupa por medida, tórax e comprimento.

Não usar grade universal como padrão. Cada categoria deve definir sua própria grade e seus próprios atributos.

## Permissões Futuras

Master:

- visão global;
- gestão de convites;
- aprovações;
- auditoria;
- dashboards consolidados.

Funcionário:

- suporte operacional;
- revisão de cadastros;
- atendimento;
- apoio aos parceiros.

Parceiro:

- gestão de produtos;
- variações;
- estoque;
- preços;
- acompanhamento de interesse e vendas.

## Estoque e Variações

O produto futuro deve ser modelado com variações explícitas. Cada variação deve ter estoque próprio, por exemplo:

- shape 8.25 pol;
- roda 54 mm;
- tênis numeração 40;
- camisa tamanho 42.

O estoque exibido no catálogo e na página de produto deve refletir a variação exata.

## Interesse em Esgotados

Produtos ou variações sem estoque devem continuar visíveis quando fizer sentido comercial. A ação futura será registrar interesse, sem simular compra indisponível.

## Dashboards Futuros

Painéis previstos:

- catálogo e qualidade de cadastro;
- estoque por variação;
- produtos esgotados com interesse;
- pedidos e conversão;
- desempenho por parceiro;
- convites originados por pesquisa;
- operação por funcionário.

## Evolução Recomendada

1. Definir modelo de dados de produtos, categorias, variações e estoque.
2. Implementar autenticação e convites.
3. Criar permissões master, funcionário e parceiro.
4. Persistir catálogo e estoque.
5. Implementar interesse em esgotados.
6. Adicionar painel administrativo real.
7. Integrar pagamento e fluxo de pedido somente depois da base operacional estar estável.

## Fase 1 Preparada

Objetivo: entregar artefatos SQL revisáveis para o usuário executar manualmente no SQL Editor do Supabase, sem conexão automática com produção.

Decisões:

- Shopping é aplicação/banco lógico separado da Pesquisa.
- Pesquisa é referenciada somente por `response_id`.
- Respostas individuais da Pesquisa não devem ser copiadas para o Shopping.
- Senhas ficam somente no Supabase Auth.
- O primeiro master é definido por SQL controlado depois que a conta existir no Auth.
- Nenhuma promoção de papel deve ser permitida pela interface.
- Funções administrativas devem exigir master ativo e gravar auditoria.
- Convites devem ser idempotentes e não guardar tokens em texto aberto.
- Elegibilidade futura via Pesquisa deve rodar em função segura no banco, exigindo `contatos_pesquisa.autorizou_contato` e Q70 com autorização explícita para ofertas comerciais.
- Aniversário fica para fase futura e exige autorização separada.

Artefatos:

- `sql/migrations/20260827_001_fase1_perfis_convites_rls.sql`
- `sql/bootstrap/bootstrap_primeiro_master.sql`
- `Documentos/fase1_bootstrap_supabase.md`
