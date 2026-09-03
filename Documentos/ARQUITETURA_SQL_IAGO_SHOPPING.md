# Arquitetura SQL - IAGO Shopping

Documento oficial da arquitetura SQL do IAGO Shopping, gerado a partir da revisão cronológica dos arquivos em `sql/migrations` e dos SQLs auxiliares em `sql/bootstrap`.

Data de referência: 29/08/2026.

## 1. Visão Geral

O banco do IAGO Shopping foi organizado como uma aplicação comercial separada, com tabelas prefixadas por `shopping_` no schema `public`, usando o Supabase Auth como fonte de identidade (`auth.users`) e o Supabase Storage para fotos de produtos.

A filosofia principal é:

- o navegador não escreve diretamente nas tabelas críticas;
- operações importantes entram por RPCs `security definer`;
- permissões diretas nas tabelas são mínimas;
- RLS protege leitura por dono ou por admin;
- auditoria registra mudanças administrativas e financeiras;
- estoque só baixa quando o pagamento é confirmado;
- o Payment Engine usa uma camada genérica para permitir trocar Mock por Mercado Pago sem mudar o frontend.

### Organização das Migrations

As migrations foram criadas por fase:

- Fase 1: perfis, convites, auditoria, papéis e RLS base.
- Fase 2: trigger de criação automática de perfil ao criar usuário no Auth.
- Fase 3: funções administrativas e status de ativação.
- Fase 5: produtos e imagens.
- Fase 6: estoque por variação e Storage.
- Fase 7: carrinho por usuário autenticado.
- Fase 8: pedidos.
- Fase 9: pagamentos, Payment Engine Mock, eventos, logs e e-mails simulados.

A Fase 0 não cria banco; ela foi frontend mock.

### Como o Frontend Conversa com o Banco

O frontend usa Supabase JS de duas formas:

- RPCs para quase toda regra de negócio;
- Storage API para upload/remoção de imagens no bucket `shopping-produtos`.

Chamadas diretas `.from(...)` ainda existem principalmente como fallback/debug do catálogo e para Storage, mas a regra de produto, estoque, carrinho, pedido e pagamento está centralizada em RPCs.

### Uso de RPCs e Funções

Existem dois tipos de função:

- RPCs públicas para telas: chamadas diretamente pelo frontend.
- Funções internas: chamadas por RPCs, triggers ou outras funções.

Exemplos de RPCs de tela:

- `shopping_perfil_atual`
- `shopping_admin_listar_perfis`
- `shopping_admin_salvar_produto_com_estoque`
- `shopping_catalogo_produtos_publicados_com_estoque`
- `shopping_carrinho_atual`
- `shopping_pedido_finalizar_carrinho`
- `shopping_pedidos_cliente_listar`
- `shopping_pagamento_criar_rpc`
- `shopping_pagamento_processar_rpc`

Exemplos de funções internas:

- `shopping_touch_atualizado_em`
- `shopping_guard_perfis_menor_privilegio`
- `shopping_admin_assert_produtos_permitido`
- `shopping_carrinho_assert_user`
- `shopping_carrinho_ativo_id`
- `shopping_pagamento_baixar_estoque_pedido`
- `shopping_pagamento_registrar_evento`
- `shopping_pagamento_enfileirar_emails`

### Uso de Triggers

Triggers são usados para:

- manter `atualizado_em`;
- criar perfil automaticamente quando um usuário nasce no Supabase Auth;
- proteger alteração indevida de perfis por usuários não master.

### Uso de RLS

RLS está ativo nas tabelas de domínio (`shopping_*`) e no Storage. A regra geral é:

- cliente vê apenas seus próprios dados;
- admin ativo vê dados operacionais;
- master controla permissões;
- anônimo vê catálogo público e imagens públicas;
- escrita crítica é feita por RPC.

## 2. Fluxo Completo do Sistema

### Fluxo Comercial Principal

```text
Cadastro/Login
  ↓
shopping_perfis
  ↓
Catálogo
  ↓
shopping_produtos + shopping_produto_imagens + shopping_produto_variacoes
  ↓
Carrinho
  ↓
shopping_carrinhos + shopping_carrinho_itens
  ↓
Pedido
  ↓
shopping_pedidos + shopping_pedido_itens
  ↓
Pagamento
  ↓
shopping_pagamentos + shopping_pagamento_eventos + shopping_pagamento_logs
  ↓
Estoque
  ↓
shopping_produto_variacoes + shopping_estoque_movimentos
  ↓
E-mails simulados
  ↓
shopping_email_fila
  ↓
Admin/Dashboard
```

### Cadastro e Login

Participam:

- `auth.users`
- `shopping_perfis`
- `shopping_auditoria`
- `shopping_convites` em cenários futuros/comerciais

Quando um usuário cria conta no Supabase Auth, o trigger `trg_shopping_auth_user_created` chama `shopping_handle_new_auth_user`, que cria um perfil `cliente`, `pendente`, de origem `cadastro_direto`.

### Catálogo

Participam:

- `shopping_produtos`
- `shopping_produto_imagens`
- `shopping_produto_variacoes`

O catálogo chama `shopping_catalogo_produtos_publicados_com_estoque`. A função retorna apenas produtos publicados, imagens ordenadas e estoque agregado. O frontend também possui fallbacks diretos para diagnóstico, mas o caminho principal é RPC.

### Cadastro de Produtos

Participam:

- `shopping_produtos`
- `shopping_produto_imagens`
- `shopping_produto_variacoes`
- `shopping_estoque_movimentos`
- `shopping_auditoria`
- `storage.objects`

O admin envia fotos ao Storage, obtém URLs públicas e chama `shopping_admin_salvar_produto_com_estoque`. Essa RPC salva o produto, substitui imagens, garante uma variação principal e registra movimentação de estoque quando necessário.

### Carrinho

Participam:

- `shopping_carrinhos`
- `shopping_carrinho_itens`
- `shopping_produtos`
- `shopping_produto_variacoes`
- `shopping_produto_imagens`

O carrinho só existe para usuário autenticado. `shopping_carrinho_ativo_id` garante um carrinho ativo por usuário. Adições e alterações validam produto publicado e saldo disponível, mas ainda não baixam estoque.

### Pedido

Participam:

- `shopping_pedidos`
- `shopping_pedido_itens`
- `shopping_carrinhos`
- `shopping_carrinho_itens`
- `shopping_produtos`
- `shopping_produto_variacoes`

`shopping_pedido_finalizar_carrinho` converte o carrinho ativo em pedido. A Fase 9 sobrescreveu essa função para não baixar estoque na finalização. O pedido nasce com `pendente_pagamento`.

### Pagamento

Participam:

- `shopping_pagamentos`
- `shopping_pagamento_mock_config`
- `shopping_pagamento_eventos`
- `shopping_pagamento_logs`
- `shopping_email_fila`
- `shopping_pedidos`
- `shopping_produto_variacoes`
- `shopping_estoque_movimentos`

O frontend chama `shopping_pagamento_criar_rpc` e `shopping_pagamento_processar_rpc`. Hoje essas funções delegam para o Mock Provider; amanhã podem delegar para Mercado Pago.

Quando o provider retorna `aprovado`, a função baixa estoque e marca o pedido como pago. Em `recusado`, `expirado` ou `timeout`, o estoque não baixa.

## 3. Tabelas `shopping_*`

### `shopping_perfis`

Objetivo: representa o perfil comercial do usuário dentro do Shopping.

Quem grava:

- Login/cadastro, via trigger `shopping_handle_new_auth_user`.
- Bootstrap do primeiro master.
- Admin/master por RPCs administrativas.

Quem lê:

- Login/header.
- Admin de perfis.
- Funções de permissão.
- Carrinho, pedidos e pagamentos indiretamente.

Quando é alterada:

- criação de conta;
- bootstrap master;
- alteração de papel;
- alteração de status;
- alteração de escopos.

Relações:

- `user_id` referencia `auth.users(id)`.
- `criado_por` e `atualizado_por` referenciam `auth.users(id)`.
- `shopping_pedidos.perfil_id` referencia `shopping_perfis(id)`.

Observações:

- `user_id` é único.
- `response_id` permite integração futura com Pesquisa IAGO sem copiar respostas.
- A proteção contra autoelevação fica no trigger `shopping_guard_perfis_menor_privilegio`.

### `shopping_convites`

Objetivo: armazenar convites comerciais de forma segura, usando hashes e sem token em texto.

Quem grava:

- Master/admin em fase de convites.
- Futuras integrações com Pesquisa IAGO.

Quem lê:

- Master.
- Futuras telas de convite/elegibilidade.

Quando é alterada:

- criação de convite;
- envio;
- aceite;
- expiração;
- cancelamento.

Relações:

- `criado_por` e `aceito_por` referenciam `auth.users(id)`.

Observações:

- `papel_destino` não pode ser `master`.
- `convite_hash` é único.
- `contato_hash` permite comparação sem expor contato cru.

### `shopping_auditoria`

Objetivo: trilha de auditoria para mudanças administrativas, perfil, produto, estoque, pedido e pagamento.

Quem grava:

- Funções administrativas.
- Funções de produto.
- Funções de estoque.
- Funções de pedido.
- Funções de pagamento.

Quem lê:

- Master/admin, conforme RLS.
- Futuro dashboard/admin de auditoria.

Quando é alterada:

- a cada evento relevante de permissão, produto, estoque, pedido ou pagamento.

Relações:

- `ator_user_id` referencia `auth.users(id)`.

Observações:

- `registro_id` é UUID genérico, pois pode apontar para tabelas diferentes.
- `antes` e `depois` guardam snapshots JSONB.

### `shopping_produtos`

Objetivo: cadastro mestre de produtos comerciais.

Quem grava:

- Admin, funcionário ou parceiro autorizado via RPC.

Quem lê:

- Catálogo.
- Página do produto.
- Carrinho.
- Admin de produtos.
- Pedidos e pagamentos indiretamente.

Quando é alterada:

- cadastro;
- edição;
- publicação;
- arquivamento;
- exclusão administrativa.

Relações:

- `criado_por` e `atualizado_por` referenciam `auth.users(id)`.
- É referenciada por `shopping_produto_imagens`, `shopping_produto_variacoes`, `shopping_estoque_movimentos`, `shopping_carrinho_itens` e `shopping_pedido_itens`.

Observações:

- `sku` é único.
- `atributos` é JSONB array para permitir categorias diferentes.
- Status: `rascunho`, `publicado`, `arquivado`.

### `shopping_produto_imagens`

Objetivo: armazenar URLs e ordem das fotos de produto.

Quem grava:

- Admin de produtos, após upload no Storage.

Quem lê:

- Catálogo.
- Página do produto.
- Admin de produtos.
- Carrinho e pedidos via snapshots ou agregações.

Quando é alterada:

- criação/edição de produto;
- escolha de foto principal;
- remoção/reordenação de imagens.

Relações:

- `produto_id` referencia `shopping_produtos(id)` com cascade.

Observações:

- `principal` indica capa.
- A arquitetura visual do frontend usa componente único e `object-fit: contain`; a tabela só guarda dados.

### `shopping_produto_variacoes`

Objetivo: controlar variações e estoque atual de cada produto.

Quem grava:

- Admin de produtos/estoque.
- Payment Engine ao baixar ou reverter estoque.

Quem lê:

- Catálogo.
- Página do produto.
- Carrinho.
- Pedidos.
- Admin.

Quando é alterada:

- cadastro de produto com estoque;
- ajuste manual de estoque;
- aprovação de pagamento;
- eventual reversão de pagamento não aprovado.

Relações:

- `produto_id` referencia `shopping_produtos(id)`.
- É referenciada por `shopping_estoque_movimentos` e `shopping_pedido_itens`.

Observações:

- Existe índice único parcial para uma variação principal por produto.
- `estoque_atual` não pode ser negativo.

### `shopping_estoque_movimentos`

Objetivo: histórico contábil de alterações de estoque.

Quem grava:

- Admin de estoque.
- Pedido na Fase 8 original.
- Payment Engine na Fase 9 atual.

Quem lê:

- Admin.
- Futuro dashboard.

Quando é alterada:

- entrada de estoque;
- ajuste;
- venda confirmada;
- reversão;
- correção manual.

Relações:

- `variacao_id` referencia `shopping_produto_variacoes(id)`.
- `produto_id` referencia `shopping_produtos(id)`.
- `criado_por` referencia `auth.users(id)`.

Observações:

- Guarda `saldo_anterior` e `saldo_posterior`.
- `quantidade` pode ser positiva ou negativa, mas não zero.

### `shopping_carrinhos`

Objetivo: carrinho ativo por usuário autenticado.

Quem grava:

- Carrinho, via `shopping_carrinho_ativo_id`.
- Pedido, ao converter carrinho para `convertido`.

Quem lê:

- Página do carrinho.
- Funções de pedido.

Quando é alterada:

- primeiro acesso ao carrinho;
- adição de item;
- finalização em pedido;
- futuro cancelamento.

Relações:

- `user_id` referencia `auth.users(id)`.
- É referenciada por `shopping_carrinho_itens` e `shopping_pedidos`.

Observações:

- Índice único parcial garante um carrinho `ativo` por usuário.

### `shopping_carrinho_itens`

Objetivo: itens escolhidos no carrinho ativo.

Quem grava:

- Página do produto/catálogo ao adicionar ao carrinho.
- Página do carrinho ao mudar quantidade ou remover.

Quem lê:

- Página do carrinho.
- Finalização do pedido.

Quando é alterada:

- adicionar produto;
- alterar quantidade;
- remover item;
- finalizar pedido.

Relações:

- `carrinho_id` referencia `shopping_carrinhos(id)`.
- `produto_id` referencia `shopping_produtos(id)`.

Observações:

- Existe unicidade por `(carrinho_id, produto_id)`.
- Preço unitário é copiado no momento da adição.

### `shopping_pedidos`

Objetivo: cabeçalho do pedido do cliente.

Quem grava:

- Carrinho, via `shopping_pedido_finalizar_carrinho`.
- Payment Engine, ao atualizar status de pagamento.

Quem lê:

- Página Meus Pedidos.
- Admin de pedidos.
- Payment Engine.
- Futuro dashboard.

Quando é alterada:

- finalização do carrinho;
- confirmação de pagamento;
- recusa/expiração/cancelamento;
- baixa de estoque confirmada.

Relações:

- `user_id` referencia `auth.users(id)`.
- `perfil_id` referencia `shopping_perfis(id)`.
- `carrinho_id` referencia `shopping_carrinhos(id)`.
- É referenciada por `shopping_pedido_itens`, `shopping_pagamentos`, `shopping_pagamento_eventos`, `shopping_pagamento_logs` e `shopping_email_fila`.

Observações:

- Após Fase 9, possui `pagamento_status`, `pagamento_confirmado_em` e `estoque_baixado_em`.
- Estoque não baixa na criação do pedido.

### `shopping_pedido_itens`

Objetivo: snapshot dos itens comprados no momento do pedido.

Quem grava:

- `shopping_pedido_finalizar_carrinho`.

Quem lê:

- Meus Pedidos.
- Admin.
- Payment Engine.
- Futuro dashboard.

Quando é alterada:

- criada junto com o pedido.
- Não deve acompanhar edições futuras do produto.

Relações:

- `pedido_id` referencia `shopping_pedidos(id)`.
- `produto_id` referencia `shopping_produtos(id)`.
- `variacao_id` referencia `shopping_produto_variacoes(id)`.

Observações:

- Guarda SKU, nome, marca, categoria, imagem, preço e quantidade como snapshot.

### `shopping_pagamentos`

Objetivo: tentativas de pagamento de um pedido.

Quem grava:

- Payment Engine Mock hoje.
- Mercado Pago futuramente.

Quem lê:

- Meus Pedidos.
- Admin de pagamentos.
- Dashboard futuro.

Quando é alterada:

- criação de tentativa;
- processamento automático;
- confirmação;
- recusa;
- expiração;
- timeout;
- cancelamento operacional.

Relações:

- `pedido_id` referencia `shopping_pedidos(id)`.
- `user_id` referencia `auth.users(id)`.
- É referenciada por `shopping_pagamento_eventos`, `shopping_pagamento_logs` e `shopping_email_fila`.

Observações:

- `referencia_externa` e `idempotency_key` são únicos.
- `checkout_payload` guarda dados do provider.
- Não movimenta dinheiro real no Mock.

### `shopping_pagamento_eventos`

Objetivo: registrar eventos de pagamento em formato semelhante a webhooks.

Quem grava:

- Payment Engine.

Quem lê:

- Admin.
- Futuro dashboard.
- Auditoria técnica.

Quando é alterada:

- criação de pagamento;
- retorno do provider;
- timeout;
- expiração;
- aprovação/recusa.

Relações:

- `pagamento_id` referencia `shopping_pagamentos(id)`.
- `pedido_id` referencia `shopping_pedidos(id)`.

Observações:

- É a base para rastrear o histórico técnico do provider.

### `shopping_pagamento_logs`

Objetivo: log operacional do Payment Engine.

Quem grava:

- Funções de pagamento.

Quem lê:

- Admin.
- Futuro dashboard técnico.

Quando é alterada:

- processamento de pagamento;
- baixa de estoque;
- timeout;
- eventos técnicos.

Relações:

- `pagamento_id` referencia `shopping_pagamentos(id)`.
- `pedido_id` referencia `shopping_pedidos(id)`.

Observações:

- Não é fila de eventos de negócio; é log técnico.

### `shopping_email_fila`

Objetivo: fila simulada de e-mails para cliente e administrador.

Quem grava:

- Payment Engine.

Quem lê:

- Admin.
- Futuro serviço real de e-mail.
- Futuro dashboard.

Quando é alterada:

- após cada status de pagamento processado.

Relações:

- `pedido_id` referencia `shopping_pedidos(id)`.
- `pagamento_id` referencia `shopping_pagamentos(id)`.

Observações:

- Hoje o envio é simulado.
- Pode evoluir para integração real de e-mail sem mudar pedidos/pagamentos.

### `shopping_pagamento_mock_config`

Objetivo: configuração singleton do Mock Provider.

Quem grava:

- Admin via `shopping_pagamento_mock_configurar`.

Quem lê:

- Payment Engine Mock.
- Admin/futuro painel de configuração.

Quando é alterada:

- ao mudar cenário de teste;
- ao mudar atraso, timeout ou expiração.

Relações:

- Sem FK.

Observações:

- Usa `id boolean primary key default true` e `check (id)` para garantir uma única linha.
- Cenários: `sempre_aprovar`, `sempre_recusar`, `aleatorio`, `timeout`, `expirar`.

## 4. Funções

### `shopping_touch_atualizado_em`

Objetivo: atualizar `new.atualizado_em = now()` antes de updates.

Quem chama: triggers `*_touch`.

Parâmetros: nenhum direto; recebe `NEW` pelo trigger.

Retorno: `trigger`.

Tabelas alteradas: a linha da tabela que disparou o trigger.

Tela responsável: indireta, qualquer tela que gere update.

Tipo: função interna de trigger.

Simplificação: faz sentido continuar; reduz duplicação.

### `shopping_is_master(p_user_id uuid)`

Objetivo: verificar se o usuário é master ativo.

Quem chama: RLS, funções administrativas e guardas.

Parâmetros: usuário; default `auth.uid()`.

Retorno: boolean.

Tabelas lidas: `shopping_perfis`.

Tipo: função interna/RPC auxiliar.

Simplificação: manter.

### `shopping_guard_perfis_menor_privilegio`

Objetivo: impedir que usuários comuns elevem papel, ativação ou escopos indevidamente.

Quem chama: trigger `trg_shopping_perfis_menor_privilegio`.

Retorno: `trigger`.

Tabelas alteradas: `shopping_perfis`.

Tipo: trigger interno.

Simplificação: manter; é camada crítica de segurança.

### `shopping_bootstrap_primeiro_master(p_user_id, p_email_normalizado, p_nome_exibicao)`

Objetivo: criar o primeiro master ativo uma única vez.

Quem chama: script auxiliar `sql/bootstrap/bootstrap_primeiro_master.sql`.

Retorno: `shopping_perfis`.

Tabelas alteradas: `shopping_perfis`, `shopping_auditoria`.

Tela responsável: nenhuma; execução manual controlada no SQL Editor.

Tipo: função administrativa manual, não frontend.

Simplificação: manter, mas só para bootstrap inicial.

### `shopping_admin_definir_papel(p_user_id, p_papel, p_motivo)`

Objetivo: master altera papel de outro usuário.

Quem chama: Admin/perfis.

Retorno: `shopping_perfis`.

Tabelas alteradas: `shopping_perfis`, `shopping_auditoria`.

Tipo: RPC frontend/admin.

Simplificação: manter.

### `shopping_admin_definir_escopos(p_user_id, p_escopos, p_motivo)`

Objetivo: master altera escopos administrativos.

Quem chama: Admin/perfis, quando houver UI de escopos.

Retorno: `shopping_perfis`.

Tabelas alteradas: `shopping_perfis`, `shopping_auditoria`.

Tipo: RPC admin.

Simplificação: manter; pode ser combinada futuramente com edição de perfil admin.

### `shopping_handle_new_auth_user`

Objetivo: criar perfil comercial automaticamente ao criar usuário em `auth.users`.

Quem chama: trigger `trg_shopping_auth_user_created`.

Retorno: `trigger`.

Tabelas alteradas: `shopping_perfis`.

Tipo: trigger interno.

Simplificação: manter.

### `shopping_is_admin(p_user_id uuid)`

Objetivo: verificar master, funcionário ou parceiro ativo.

Quem chama: RLS, Storage policies e RPCs administrativas.

Retorno: boolean.

Tabelas lidas: `shopping_perfis`.

Tipo: função auxiliar.

Simplificação: manter.

### `shopping_perfil_atual`

Objetivo: retornar o perfil do usuário autenticado atual.

Quem chama: frontend de autenticação/header/admin.

Parâmetros: nenhum.

Retorno: tabela com dados de perfil.

Tabelas lidas: `shopping_perfis`.

Tipo: RPC chamada pelo frontend.

Simplificação: manter.

### `shopping_admin_listar_perfis`

Objetivo: listar perfis para administração.

Quem chama: tela Admin.

Parâmetros: nenhum.

Retorno: tabela de perfis.

Tabelas lidas: `shopping_perfis`.

Tipo: RPC frontend/admin.

Simplificação: manter.

### `shopping_admin_definir_status_ativacao(p_user_id, p_status_ativacao, p_motivo)`

Objetivo: master altera status de ativação.

Quem chama: Admin/perfis.

Retorno: `shopping_perfis`.

Tabelas alteradas: `shopping_perfis`, `shopping_auditoria`.

Tipo: RPC frontend/admin.

Simplificação: manter.

### `shopping_admin_assert_produtos_permitido`

Objetivo: garantir usuário autenticado, ativo e com papel administrativo.

Quem chama: RPCs de produto, estoque, pedidos admin, pagamentos admin e config mock.

Retorno: `shopping_perfis`.

Tabelas lidas: `shopping_perfis`.

Tipo: função interna.

Simplificação: manter.

### `shopping_admin_listar_produtos`

Objetivo: listar produtos com imagens para admin, antes da fase de estoque.

Quem chama: legado.

Retorno: produtos com JSON de imagens.

Tabelas lidas: `shopping_produtos`, `shopping_produto_imagens`.

Tipo: RPC legada.

Simplificação: pode virar obsoleta, pois o frontend atual usa `shopping_admin_listar_produtos_com_estoque`.

### `shopping_catalogo_produtos_publicados`

Objetivo: listar catálogo publicado sem estoque.

Quem chama: legado/fase anterior.

Retorno: produtos publicados com imagens.

Tabelas lidas: `shopping_produtos`, `shopping_produto_imagens`.

Tipo: RPC legada pública.

Simplificação: pode ser mantida como fallback, mas a principal é `shopping_catalogo_produtos_publicados_com_estoque`.

### `shopping_admin_salvar_produto`

Objetivo: criar/editar produto e imagens.

Quem chama: `shopping_admin_salvar_produto_com_estoque`.

Retorno: `shopping_produtos`.

Tabelas alteradas: `shopping_produtos`, `shopping_produto_imagens`, `shopping_auditoria`.

Tipo: função base interna/RPC possível.

Simplificação: manter como núcleo sem estoque.

### `shopping_admin_excluir_produto(p_id, p_motivo)`

Objetivo: excluir produto com auditoria.

Quem chama: Admin de produtos.

Retorno: void.

Tabelas alteradas: `shopping_produtos` e dependentes por cascade; `shopping_auditoria`.

Tipo: RPC frontend/admin.

Simplificação: manter, mas avaliar arquivamento no lugar de exclusão física.

### `shopping_admin_definir_estoque_produto(p_produto_id, p_quantidade_estoque, p_motivo)`

Objetivo: criar/atualizar variação principal e ajustar estoque.

Quem chama: `shopping_admin_salvar_produto_com_estoque` e telas futuras de estoque.

Retorno: `shopping_produto_variacoes`.

Tabelas alteradas: `shopping_produto_variacoes`, `shopping_estoque_movimentos`, `shopping_auditoria`.

Tipo: função admin.

Simplificação: manter.

### `shopping_admin_salvar_produto_com_estoque`

Objetivo: salvar produto, imagens e estoque em uma operação.

Quem chama: Admin de produtos.

Retorno: `shopping_produtos`.

Tabelas alteradas: `shopping_produtos`, `shopping_produto_imagens`, `shopping_produto_variacoes`, `shopping_estoque_movimentos`, `shopping_auditoria`.

Tipo: RPC frontend/admin.

Simplificação: manter como RPC principal da tela de cadastro.

### `shopping_admin_listar_produtos_com_estoque`

Objetivo: listar produtos, imagens e estoque para admin.

Quem chama: Admin de produtos.

Retorno: tabela com produto, imagens e quantidade de estoque.

Tabelas lidas: `shopping_produtos`, `shopping_produto_imagens`, `shopping_produto_variacoes`.

Tipo: RPC frontend/admin.

Simplificação: manter.

### `shopping_catalogo_produtos_publicados_com_estoque`

Objetivo: listar catálogo público com estoque real.

Quem chama: Catálogo e página do produto.

Retorno: produtos publicados, imagens e quantidade de estoque.

Tabelas lidas: `shopping_produtos`, `shopping_produto_imagens`, `shopping_produto_variacoes`.

Tipo: RPC pública para anon/authenticated.

Simplificação: manter como fonte principal do catálogo.

### `shopping_carrinho_assert_user`

Objetivo: garantir usuário autenticado e perfil existente para carrinho.

Quem chama: funções de carrinho, pedido e pagamento.

Retorno: uuid do usuário.

Tabelas lidas: `shopping_perfis`.

Tipo: função interna.

Simplificação: manter.

### `shopping_carrinho_ativo_id`

Objetivo: retornar ou criar carrinho ativo do usuário.

Quem chama: funções de carrinho.

Retorno: uuid do carrinho.

Tabelas alteradas: `shopping_carrinhos`.

Tipo: função interna.

Simplificação: manter.

### `shopping_carrinho_atual`

Objetivo: listar o carrinho ativo com dados de produto, imagem e estoque.

Quem chama: página Carrinho.

Retorno: tabela de itens do carrinho.

Tabelas lidas: `shopping_carrinhos`, `shopping_carrinho_itens`, `shopping_produtos`, `shopping_produto_imagens`, `shopping_produto_variacoes`.

Tipo: RPC frontend.

Simplificação: manter.

### `shopping_carrinho_adicionar_produto(p_produto_id, p_quantidade)`

Objetivo: adicionar produto publicado ao carrinho validando estoque.

Quem chama: Catálogo e página do produto.

Retorno: `shopping_carrinho_itens`.

Tabelas alteradas: `shopping_carrinhos`, `shopping_carrinho_itens`.

Tipo: RPC frontend.

Simplificação: manter.

### `shopping_carrinho_definir_quantidade(p_item_id, p_quantidade)`

Objetivo: alterar quantidade de um item do carrinho.

Quem chama: página Carrinho.

Retorno: `shopping_carrinho_itens`.

Tabelas alteradas: `shopping_carrinho_itens`.

Tipo: RPC frontend.

Simplificação: manter.

### `shopping_carrinho_remover_item(p_item_id)`

Objetivo: remover item do carrinho ativo.

Quem chama: página Carrinho.

Retorno: void.

Tabelas alteradas: `shopping_carrinho_itens`.

Tipo: RPC frontend.

Simplificação: manter.

### `shopping_pedido_finalizar_carrinho`

Objetivo: converter carrinho ativo em pedido.

Quem chama: página Carrinho.

Retorno: `shopping_pedidos`.

Tabelas alteradas: `shopping_pedidos`, `shopping_pedido_itens`, `shopping_carrinhos`, `shopping_auditoria`.

Tipo: RPC frontend.

Observação: a versão atual da Fase 9 não baixa estoque; estoque só baixa após pagamento aprovado.

Simplificação: manter.

### `shopping_pedidos_cliente_listar`

Objetivo: listar pedidos do cliente com itens e último pagamento.

Quem chama: checkout.

Retorno: tabela de pedidos com JSON de itens e dados de pagamento.

Tabelas lidas: `shopping_pedidos`, `shopping_pedido_itens`, `shopping_pagamentos`.

Tipo: RPC frontend.

Simplificação: manter.

### `shopping_admin_listar_pedidos`

Objetivo: listar pedidos para administração.

Quem chama: Admin.

Retorno: tabela de pedidos com itens e dados de pagamento.

Tabelas lidas: `shopping_pedidos`, `shopping_pedido_itens`, `shopping_pagamentos`.

Tipo: RPC frontend/admin.

Simplificação: manter.

### `shopping_pagamento_registrar_evento(p_pagamento_id, p_pedido_id, p_tipo, p_status, p_payload)`

Objetivo: criar evento técnico/de negócio de pagamento.

Quem chama: funções do Payment Engine.

Retorno: void.

Tabelas alteradas: `shopping_pagamento_eventos`, `shopping_pagamento_logs`.

Tipo: função interna.

Simplificação: manter.

### `shopping_pagamento_enfileirar_emails(p_pagamento_id, p_pedido_id, p_status)`

Objetivo: criar mensagens simuladas para cliente e admin.

Quem chama: funções do Payment Engine.

Retorno: void.

Tabelas alteradas: `shopping_email_fila`.

Tipo: função interna.

Simplificação: manter até virar integração real.

### `shopping_pagamento_baixar_estoque_pedido(p_pedido_id)`

Objetivo: baixar estoque dos itens de um pedido aprovado.

Quem chama: processamento de pagamento aprovado.

Retorno: void.

Tabelas alteradas: `shopping_produto_variacoes`, `shopping_estoque_movimentos`, `shopping_pedidos`, `shopping_pagamento_logs`.

Tipo: função interna crítica.

Simplificação: manter.

### `shopping_pagamento_reverter_estoque_pedido(p_pedido_id)`

Objetivo: reverter baixa de estoque quando aplicável e quando pedido não está aprovado.

Quem chama: processamento de status negativos.

Retorno: void.

Tabelas alteradas: `shopping_produto_variacoes`, `shopping_estoque_movimentos`, `shopping_pedidos`.

Tipo: função interna.

Simplificação: manter, mas deve ser testada com cenários reais de estorno.

### `shopping_pagamento_mock_criar(p_pedido_id, p_metodo)`

Objetivo: criar tentativa de pagamento mock para pedido do usuário.

Quem chama: wrapper `shopping_pagamento_mock_criar_rpc`.

Retorno: `shopping_pagamentos`.

Tabelas alteradas: `shopping_pagamentos`, `shopping_pedidos`, `shopping_pagamento_eventos`, `shopping_email_fila`, `shopping_auditoria`.

Tipo: função interna do provider mock.

Simplificação: manter enquanto Mock existir.

### `shopping_pagamento_mock_simular(p_pagamento_id, p_resultado, p_payload)`

Objetivo: aplicar resultado de provider mock com todos os efeitos colaterais.

Quem chama: `shopping_pagamento_mock_processar_rpc`.

Retorno: `shopping_pagamentos`.

Tabelas alteradas: `shopping_pagamentos`, `shopping_pedidos`, `shopping_produto_variacoes`, `shopping_estoque_movimentos`, `shopping_pagamento_eventos`, `shopping_email_fila`, `shopping_auditoria`.

Tipo: função interna do provider mock. Antes era RPC manual; no fluxo atual não é chamada pelo frontend.

Simplificação: pode ser renomeada futuramente para `shopping_pagamento_aplicar_resultado_provider`.

### `shopping_admin_listar_pagamentos`

Objetivo: listar tentativas de pagamento para administração.

Quem chama: Admin.

Retorno: tabela de pagamentos com pedido, cliente, eventos e e-mails.

Tabelas lidas: `shopping_pagamentos`, `shopping_pedidos`, `shopping_pagamento_eventos`, `shopping_email_fila`.

Tipo: RPC frontend/admin.

Simplificação: manter.

### `shopping_pagamento_mock_criar_rpc(p_pedido_id, p_metodo text)`

Objetivo: wrapper compatível com Supabase RPC para criar pagamento mock recebendo método como texto.

Quem chama: `shopping_pagamento_criar_rpc`.

Retorno: `shopping_pagamentos`.

Tabelas alteradas: indiretamente as mesmas de `shopping_pagamento_mock_criar`.

Tipo: wrapper interno/RPC compatível.

Simplificação: pode ser removida quando o provider genérico deixar de delegar ao mock por esta função.

### `shopping_pagamento_mock_configurar(p_cenario, p_atraso_ms, p_timeout_ms, p_expiracao_ms)`

Objetivo: configurar cenário do Mock Provider.

Quem chama: admin via SQL Editor hoje; futuro painel admin.

Retorno: `shopping_pagamento_mock_config`.

Tabelas alteradas: `shopping_pagamento_mock_config`, `shopping_auditoria`.

Tipo: RPC administrativa.

Simplificação: manter enquanto Mock existir.

### `shopping_pagamento_mock_processar_rpc(p_pagamento_id)`

Objetivo: simular automaticamente retorno do provider mock conforme configuração.

Quem chama: `shopping_pagamento_processar_rpc`.

Retorno: `shopping_pagamentos`.

Tabelas alteradas: indiretamente as mesmas de `shopping_pagamento_mock_simular`; em timeout também atualiza erro e logs.

Tipo: função do provider mock.

Simplificação: manter até Mercado Pago real.

### `shopping_pagamento_criar_rpc(p_pedido_id, p_metodo text)`

Objetivo: entrada genérica do frontend para criar pagamento pelo provider configurado.

Quem chama: checkout.

Retorno: `shopping_pagamentos`.

Tabelas alteradas: via provider.

Tipo: RPC frontend.

Simplificação: manter. É a abstração correta para futuro Mercado Pago.

### `shopping_pagamento_processar_rpc(p_pagamento_id)`

Objetivo: entrada genérica do frontend para processar/acompanhar tentativa no provider configurado.

Quem chama: página Meus Pedidos.

Retorno: `shopping_pagamentos`.

Tabelas alteradas: via provider.

Tipo: RPC frontend hoje; futuramente o webhook real deve chamar lógica equivalente.

Simplificação: manter, mas quando houver Mercado Pago real o processamento final deve vir de webhook backend/provider.

### `shopping_pagamento_cancelar_tentativa_rpc(p_pagamento_id, p_payload)`

Objetivo: cancelar somente a tentativa de pagamento ativa, sem cancelar o pedido.

Quem chama: checkout e backend de pagamentos.

Retorno: `shopping_pagamentos`.

Tabelas alteradas: `shopping_pagamentos`, `shopping_pedidos`, `shopping_pagamento_eventos`, `shopping_pagamento_logs`, `shopping_auditoria`.

Tipo: RPC frontend/backend.

Simplificação: manter. Ela separa cancelamento de tentativa de cancelamento de pedido, que são conceitos diferentes.

## 5. Triggers

| Trigger | Tabela | Momento | Função | Efeito |
|---|---|---|---|---|
| `trg_shopping_perfis_touch` | `shopping_perfis` | `before update` | `shopping_touch_atualizado_em` | Atualiza `atualizado_em`. |
| `trg_shopping_convites_touch` | `shopping_convites` | `before update` | `shopping_touch_atualizado_em` | Atualiza `atualizado_em`. |
| `trg_shopping_perfis_menor_privilegio` | `shopping_perfis` | `before insert or update` | `shopping_guard_perfis_menor_privilegio` | Impede autoelevação de papel/status/escopos. |
| `trg_shopping_auth_user_created` | `auth.users` | `after insert` | `shopping_handle_new_auth_user` | Cria perfil do cliente automaticamente. |
| `trg_shopping_produtos_touch` | `shopping_produtos` | `before update` | `shopping_touch_atualizado_em` | Atualiza `atualizado_em`. |
| `trg_shopping_produto_imagens_touch` | `shopping_produto_imagens` | `before update` | `shopping_touch_atualizado_em` | Atualiza `atualizado_em`. |
| `trg_shopping_produto_variacoes_touch` | `shopping_produto_variacoes` | `before update` | `shopping_touch_atualizado_em` | Atualiza `atualizado_em`. |
| `trg_shopping_carrinhos_touch` | `shopping_carrinhos` | `before update` | `shopping_touch_atualizado_em` | Atualiza `atualizado_em`. |
| `trg_shopping_carrinho_itens_touch` | `shopping_carrinho_itens` | `before update` | `shopping_touch_atualizado_em` | Atualiza `atualizado_em`. |
| `trg_shopping_pedidos_touch` | `shopping_pedidos` | `before update` | `shopping_touch_atualizado_em` | Atualiza `atualizado_em`. |
| `trg_shopping_pagamentos_touch` | `shopping_pagamentos` | `before update` | `shopping_touch_atualizado_em` | Atualiza `atualizado_em`. |
| `trg_shopping_pagamento_mock_config_touch` | `shopping_pagamento_mock_config` | `before update` | `shopping_touch_atualizado_em` | Atualiza `atualizado_em`. |

## 6. RLS e Políticas

### `shopping_perfis`

Políticas:

- `shopping_perfis_select_self_or_master`: usuário lê o próprio perfil; master lê todos.
- `shopping_perfis_insert_self_cliente`: usuário cria apenas seu próprio perfil como cliente.
- `shopping_perfis_update_self_limited_or_master`: usuário edita campos limitados do próprio perfil; master pode editar.

Permissões:

- `authenticated`: select/insert e update limitado por colunas.
- `anon`: sem acesso direto.

Observação: pode haver redundância entre trigger e RLS, mas a redundância é útil por segurança.

### `shopping_convites`

Política:

- `shopping_convites_master_all`: master controla convites.

Permissões:

- `authenticated`: select/insert/update, condicionado por RLS.
- `anon`: sem acesso.

Observação: fase ainda incompleta no produto final.

### `shopping_auditoria`

Política:

- `shopping_auditoria_master_select`: master lê auditoria.

Permissões:

- `authenticated`: select condicionado.
- escrita ocorre por funções `security definer`.

### `shopping_produtos`

Política:

- `shopping_produtos_select_public_or_admin`: anônimo/autenticado lê publicados; admin lê também rascunhos/arquivados.

Permissões:

- `anon` e `authenticated`: select.
- escrita via RPC.

### `shopping_produto_imagens`

Política:

- `shopping_produto_imagens_select_public_or_admin`: leitura quando produto está publicado ou usuário é admin.

Permissões:

- `anon` e `authenticated`: select.
- escrita via RPC após upload.

### `shopping_produto_variacoes`

Política:

- `shopping_produto_variacoes_select_public_or_admin`: leitura de variações ativas/publicadas; admin vê mais.

Permissões:

- escrita via RPC.

### `shopping_estoque_movimentos`

Política:

- `shopping_estoque_movimentos_select_admin`: apenas admin lê histórico de estoque.

Permissões:

- escrita via funções.

### Storage `shopping-produtos`

Políticas em `storage.objects`:

- `shopping_produtos_storage_select_public`: leitura pública.
- `shopping_produtos_storage_insert_admin`: admin insere arquivos.
- `shopping_produtos_storage_update_admin`: admin atualiza arquivos.
- `shopping_produtos_storage_delete_admin`: admin remove arquivos.

Observação: não é tabela `shopping_`, mas faz parte da arquitetura de imagens.

### `shopping_carrinhos`

Política:

- `shopping_carrinhos_select_own`: usuário lê o próprio carrinho.

Permissões:

- escrita via RPC.
- `anon`: sem acesso.

### `shopping_carrinho_itens`

Política:

- `shopping_carrinho_itens_select_own`: usuário lê itens do próprio carrinho.

Permissões:

- escrita via RPC.
- `anon`: sem acesso.

### `shopping_pedidos`

Política:

- `shopping_pedidos_select_own_or_admin`: cliente lê seus pedidos; admin lê pedidos operacionais.

Permissões:

- select para authenticated.
- escrita via RPC.

### `shopping_pedido_itens`

Política:

- `shopping_pedido_itens_select_own_or_admin`: cliente lê itens dos próprios pedidos; admin lê todos.

Permissões:

- select para authenticated.
- escrita via RPC.

### `shopping_pagamentos`

Política:

- `shopping_pagamentos_select_own_or_admin`: cliente lê próprios pagamentos; admin lê todos.

Permissões:

- select para authenticated.
- escrita via RPC.

### `shopping_pagamento_eventos`

Política:

- `shopping_pagamento_eventos_select_own_or_admin`: cliente/admin leem eventos associados aos próprios pagamentos ou todos se admin.

Permissões:

- select para authenticated.
- escrita via funções.

### `shopping_pagamento_logs`

Política:

- `shopping_pagamento_logs_select_admin`: apenas admin lê logs técnicos.

Permissões:

- select para authenticated condicionado.
- escrita via funções.

### `shopping_email_fila`

Política:

- `shopping_email_fila_select_admin`: apenas admin lê fila simulada.

Permissões:

- select para authenticated condicionado.
- escrita via funções.

### `shopping_pagamento_mock_config`

Política:

- `shopping_pagamento_mock_config_select_admin`: admin lê configuração do Mock.

Permissões:

- select para authenticated condicionado.
- alteração via `shopping_pagamento_mock_configurar`.

## 7. Migrations

| Migration | Objetivo | O que criou | O que alterou |
|---|---|---|---|
| `20260827_001_fase1_perfis_convites_rls.sql` | Base de perfis, convites e auditoria | enums de perfil, tabelas `shopping_perfis`, `shopping_convites`, `shopping_auditoria`, funções de master, auditoria e RLS | Estrutura inicial |
| `20260828_001_fase2_auth_trigger_perfis.sql` | Integrar Auth com perfis | trigger em `auth.users` e função `shopping_handle_new_auth_user` | Automatiza criação de perfil |
| `20260828_002_fase3_admin_permissoes.sql` | Administração de perfis | funções `shopping_is_admin`, `shopping_perfil_atual`, `shopping_admin_listar_perfis`, `shopping_admin_definir_status_ativacao` | Ajusta FKs para `on delete set null` |
| `20260828_003_fase5_cadastro_produtos.sql` | Cadastro de produtos | `shopping_produtos`, `shopping_produto_imagens`, status de produto, RPCs de produto | Introduz catálogo real sem estoque |
| `20260828_004_fase6_estoque.sql` | Estoque por variação | `shopping_produto_variacoes`, `shopping_estoque_movimentos`, tipo de movimento, RPCs com estoque | Catálogo/admin passam a considerar estoque |
| `20260828_005_fase6_storage_fotos_produtos.sql` | Fotos em Storage | bucket `shopping-produtos` e policies de Storage | Habilita upload público controlado |
| `20260828_006_fase7_carrinho.sql` | Carrinho autenticado | `shopping_carrinhos`, `shopping_carrinho_itens`, status de carrinho e RPCs | Adição/edição/remoção de itens |
| `20260828_007_fase8_pedidos.sql` | Pedidos | `shopping_pedidos`, `shopping_pedido_itens`, status de pedido e RPCs | Converte carrinho em pedido |
| `20260828_008_fase9_pagamentos.sql` | Payment Engine Mock | tabelas de pagamentos, eventos, logs, e-mails; tipos de pagamento; funções de baixa de estoque | Move baixa de estoque para pagamento aprovado |
| `20260828_009_fase9_pagamentos_rpc_compat.sql` | Compatibilidade RPC | wrapper `shopping_pagamento_mock_criar_rpc` | Evita erro de assinatura enum no Supabase |
| `20260829_010_fase9_pagamentos_mock_automatico.sql` | Mock automático produção-like | `shopping_pagamento_mock_config`, RPCs genéricas e processamento automático | Remove fluxo manual do cliente e adiciona erro/timeout em listagens |
| `20260829_011_fase9a_mercado_pago_sandbox.sql` | Mercado Pago Sandbox | provider config, campos oficiais de provider, Pix, webhook, sincronização e auditoria | Integra Checkout Transparente sem credenciais no banco |
| `20260829_012_fase9b_cancelamento_pagamento.sql` | Cancelamento de tentativa | `shopping_pagamento_cancelar_tentativa_rpc` e listagens que ignoram tentativa cancelada como ativa | Permite cancelar pagamento sem cancelar pedido |

### SQL auxiliar

`sql/bootstrap/bootstrap_primeiro_master.sql` chama `shopping_bootstrap_primeiro_master` manualmente depois de criada a conta no Auth. Não contém senha e não deve ser executado pelo frontend.

## 8. Fluxos Visuais

### Produto até Dashboard

```text
shopping_produtos
  ↓
shopping_produto_imagens
  ↓
shopping_produto_variacoes
  ↓
Catálogo
  ↓
Carrinho
  ↓
Pedido
  ↓
Pagamento
  ↓
Estoque
  ↓
Email simulado
  ↓
Dashboard/Admin
```

### Admin Cadastra Produto

```text
Admin
  ↓
Upload Storage: shopping-produtos
  ↓
shopping_admin_salvar_produto_com_estoque
  ↓
shopping_produtos
  ↓
shopping_produto_imagens
  ↓
shopping_produto_variacoes
  ↓
shopping_estoque_movimentos
  ↓
shopping_auditoria
```

### Cliente Compra

```text
Cliente autenticado
  ↓
shopping_carrinho_adicionar_produto
  ↓
shopping_carrinhos
  ↓
shopping_carrinho_itens
  ↓
shopping_pedido_finalizar_carrinho
  ↓
shopping_pedidos
  ↓
shopping_pedido_itens
  ↓
shopping_pagamento_criar_rpc
  ↓
shopping_pagamento_processar_rpc
```

### Payment Engine

```text
Tela Meus Pedidos
  ↓
shopping_pagamento_criar_rpc
  ↓
shopping_pagamento_mock_criar_rpc
  ↓
shopping_pagamento_mock_criar
  ↓
shopping_pagamentos
  ↓
shopping_pagamento_processar_rpc
  ↓
shopping_pagamento_mock_processar_rpc
  ↓
shopping_pagamento_mock_simular
  ↓
shopping_pagamento_eventos
  ↓
shopping_email_fila
  ↓
shopping_pagamento_logs
```

### Pagamento Aprovado

```text
Provider retorna aprovado
  ↓
shopping_pagamento_mock_simular
  ↓
shopping_pagamento_baixar_estoque_pedido
  ↓
shopping_produto_variacoes.estoque_atual
  ↓
shopping_estoque_movimentos
  ↓
shopping_pedidos.pagamento_status = aprovado
  ↓
shopping_email_fila
```

### Permissões

```text
auth.users
  ↓
trg_shopping_auth_user_created
  ↓
shopping_perfis
  ↓
shopping_is_master / shopping_is_admin
  ↓
RLS
  ↓
RPCs administrativas
```

## 9. Auditoria da Arquitetura

### Tabelas possivelmente incompletas ou futuras

- `shopping_convites`: preparada, mas ainda sem fluxo completo de convite no frontend.
- `shopping_email_fila`: hoje simula envio; precisa de worker/integração real.
- `shopping_pagamento_mock_config`: útil em homologação; em produção real pode ficar restrita ou desabilitada.

### Funções duplicadas ou antigas

- `shopping_admin_listar_produtos` e `shopping_catalogo_produtos_publicados` são versões pré-estoque. O caminho atual usa as versões `*_com_estoque`.
- `shopping_pagamento_mock_simular` era chamada manualmente no início da Fase 9; agora é função interna do provider mock.
- `shopping_pagamento_mock_criar_rpc` é wrapper de compatibilidade. A entrada oficial do frontend agora é `shopping_pagamento_criar_rpc`.

### Migrations obsoletas ou sobrepostas

- Fase 8 criou baixa de estoque ao finalizar pedido, mas Fase 9 sobrescreveu `shopping_pedido_finalizar_carrinho` para baixar estoque somente após pagamento.
- Fase 9 `008` e `010` recriam funções de listagem de pedidos. Isso é correto pela evolução, mas exige atenção em deploys manuais.

### SQL legado

- RPCs sem estoque podem ser mantidas como legado, mas documentadas como não preferenciais.
- A nomenclatura `mock_simular` continua interna; futuramente pode virar uma função genérica `aplicar_resultado_provider`.

### Possíveis gargalos

- Catálogo agrega imagens e estoque por produto; com muitos produtos, pode precisar de índices adicionais ou view materializada.
- Admin de pagamentos conta eventos/e-mails por lateral subquery; em grande volume pode precisar de agregação pré-calculada.
- Busca de catálogo ainda depende de filtragem no frontend; busca textual em banco pode melhorar performance.

### Melhorias de performance

- Criar índice em `shopping_produto_imagens(produto_id, principal desc, ordem)`.
- Avaliar índice em `shopping_pedidos(user_id, pagamento_status, criado_em desc)`.
- Avaliar índice em `shopping_pagamentos(pedido_id, status, criado_em desc)`.
- Considerar paginação real no RPC do catálogo e admin quando houver muitos itens.

### Melhorias de segurança

- Evitar grants diretos de select em logs/e-mails para usuários comuns; a RLS já restringe, mas uma RPC admin-only seria mais limpa.
- Desabilitar ou restringir `shopping_pagamento_mock_configurar` fora de homologação.
- Quando Mercado Pago entrar, validar webhooks no backend com assinatura/segredo fora do SQL.
- Preferir arquivar produto em vez de excluir fisicamente quando houver pedido histórico.

### Melhorias de organização

- Consolidar funções legadas de catálogo/produto em uma migration de limpeza futura.
- Separar funções internas de provider em nomes genéricos.
- Criar documentação automática de RPCs a partir das migrations para evitar drift.
- Criar um painel admin para configuração do Mock em vez de SQL manual.

## 10. Checklist Final

| Item | Status | Observações |
|---|---|---|
| Produtos | Completo | Cadastro, imagens múltiplas, capa e categorias funcionando. |
| Estoque | Completo localmente | Estoque por variação principal e histórico de movimentos. |
| Carrinho | Completo localmente | Apenas usuário autenticado monta carrinho. |
| Pedidos | Completo | Carrinho vira pedido; baixa de estoque movida para pagamento aprovado. |
| Payment Engine | Completo localmente | Mock automático e arquitetura pronta para provider real. |
| Emails | Parcial | Fila simulada criada; falta envio real. |
| Dashboard | Não iniciado | Admin já tem dados básicos; dashboard agregado é fase futura. |
| Perfis | Completo | Perfil automático, papel, status e escopos. |
| Permissões | Completo | RLS, funções admin e checks por papel. |
| Convites | Parcial | Estrutura segura criada; fluxo frontend ainda futuro. |
| Auditoria | Completo localmente | Eventos principais registram antes/depois e motivo. |
| Logs | Parcial | Logs de pagamento existem; dashboard/log viewer futuro. |
| Mercado Pago | Parcial | Sandbox integrado ao Payment Engine, Payment Brick no checkout, Pix com QR/copia e cola quando devolvido pelo provider, webhooks preparados; falta homologação/produção real. |
| Storage | Completo localmente | Bucket e policies de fotos de produto. |
| Pesquisa IAGO | Não iniciado | `response_id` preparado; integração segura futura. |
