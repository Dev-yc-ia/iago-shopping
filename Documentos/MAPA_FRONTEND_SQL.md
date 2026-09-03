# Mapa Frontend x SQL - IAGO Shopping

Este documento mostra o caminho inverso da arquitetura: parte das telas e ações do sistema e mostra quais RPCs, tabelas e efeitos colaterais participam.

Data de referência: 29/08/2026.

## Visão Geral

O frontend conversa com Supabase principalmente por RPC. A regra é:

- tela chama RPC;
- RPC valida usuário/permissão;
- RPC lê/escreve tabelas;
- triggers atualizam campos automáticos;
- RLS limita leitura direta;
- Storage é usado apenas para arquivos de imagem.

## Tela: Entrada/Login

Arquivos principais:

- `frontend/index.html`
- `frontend/login.html`
- `frontend/features/login.js`
- `frontend/features/auth.js`

### Ação: criar conta ou login

RPCs chamadas:

- nenhuma para criar usuário; Supabase Auth cuida do cadastro/login.
- depois do login, `shopping_perfil_atual`.

Tabelas envolvidas:

- `auth.users`
- `shopping_perfis`

Efeitos colaterais:

- trigger `trg_shopping_auth_user_created` cria perfil automaticamente.
- perfil nasce como `cliente`, `pendente`, `cadastro_direto`.

Fluxo:

```text
Login/Cadastro
  ↓
Supabase Auth
  ↓
auth.users
  ↓
trg_shopping_auth_user_created
  ↓
shopping_handle_new_auth_user
  ↓
shopping_perfis
```

## Tela: Header/Navegação

Arquivo principal:

- `frontend/features/auth.js`

### Ação: detectar usuário atual

RPCs chamadas:

- `shopping_perfil_atual`

Tabelas lidas:

- `shopping_perfis`

Efeitos colaterais:

- nenhum.

Uso na tela:

- decide se mostra Admin;
- decide se mostra Carrinho/Pedidos;
- controla estado de login/logout.

## Tela: Catálogo

Arquivos principais:

- `frontend/catalogo.html`
- `frontend/features/catalog.js`
- `frontend/config/products.js`

### Ação: carregar produtos publicados

RPC principal:

- `shopping_catalogo_produtos_publicados_com_estoque`

Fallbacks/debug encontrados:

- leitura direta de `shopping_produtos`
- leitura direta de `shopping_produto_imagens`
- leitura direta de `shopping_produto_variacoes`

Tabelas lidas:

- `shopping_produtos`
- `shopping_produto_imagens`
- `shopping_produto_variacoes`

Efeitos colaterais:

- nenhum.

Regras:

- produto deve estar `publicado`;
- estoque é calculado pelas variações ativas;
- imagens são agregadas em JSON;
- primeira/capa é usada nas listagens.

Fluxo:

```text
Catálogo
  ↓
shopping_catalogo_produtos_publicados_com_estoque
  ↓
shopping_produtos
  ↓
shopping_produto_imagens
  ↓
shopping_produto_variacoes
```

### Ação: filtrar por categoria, busca, marca ou disponibilidade

RPCs chamadas:

- a mesma RPC de catálogo; filtros são aplicados no frontend.

Tabelas lidas:

- mesmas do catálogo.

Efeitos colaterais:

- nenhum.

Observação:

- com volume maior, filtros deveriam migrar para parâmetros da RPC.

## Tela: Produto Individual

Arquivos principais:

- `frontend/produto.html`
- `frontend/features/product.js`
- `frontend/config/products.js`

### Ação: abrir produto

RPC principal:

- `shopping_catalogo_produtos_publicados_com_estoque`

Tabelas lidas:

- `shopping_produtos`
- `shopping_produto_imagens`
- `shopping_produto_variacoes`

Efeitos colaterais:

- evento local `product_view` no analytics do navegador.

Observação:

- a página filtra localmente o produto pelo `id` da URL.
- as imagens usam componente reutilizável com `object-fit: contain`.

### Ação: adicionar ao carrinho

RPC chamada:

- `shopping_carrinho_adicionar_produto`

Tabelas lidas:

- `shopping_perfis`
- `shopping_carrinhos`
- `shopping_produtos`
- `shopping_produto_variacoes`

Tabelas escritas:

- `shopping_carrinhos`
- `shopping_carrinho_itens`

Efeitos colaterais:

- cria carrinho ativo se não existir;
- soma quantidade se item já existe;
- valida estoque antes de adicionar;
- se usuário não está logado, frontend redireciona para login.

Fluxo:

```text
Produto
  ↓
Adicionar ao carrinho
  ↓
shopping_carrinho_adicionar_produto
  ↓
shopping_carrinho_ativo_id
  ↓
shopping_carrinhos
  ↓
shopping_carrinho_itens
```

## Tela: Carrinho

Arquivos principais:

- `frontend/carrinho.html`
- `frontend/features/cart.js`

### Ação: carregar carrinho ativo

RPC chamada:

- `shopping_carrinho_atual`

Tabelas lidas:

- `shopping_carrinhos`
- `shopping_carrinho_itens`
- `shopping_produtos`
- `shopping_produto_imagens`
- `shopping_produto_variacoes`

Efeitos colaterais:

- cria carrinho ativo se necessário.

### Ação: aumentar/reduzir quantidade

RPC chamada:

- `shopping_carrinho_definir_quantidade`

Tabelas lidas:

- `shopping_carrinhos`
- `shopping_carrinho_itens`
- `shopping_produto_variacoes`

Tabelas escritas:

- `shopping_carrinho_itens`

Efeitos colaterais:

- valida dono do carrinho;
- valida estoque disponível;
- trigger atualiza `atualizado_em`.

### Ação: remover item

RPC chamada:

- `shopping_carrinho_remover_item`

Tabelas escritas:

- `shopping_carrinho_itens`

Efeitos colaterais:

- item é excluído do carrinho ativo do usuário.

### Ação: finalizar pedido

RPC chamada:

- `shopping_pedido_finalizar_carrinho`

Tabelas lidas:

- `shopping_perfis`
- `shopping_carrinhos`
- `shopping_carrinho_itens`
- `shopping_produtos`
- `shopping_produto_variacoes`
- `shopping_produto_imagens`

Tabelas escritas:

- `shopping_pedidos`
- `shopping_pedido_itens`
- `shopping_carrinhos`
- `shopping_auditoria`

Efeitos colaterais:

- carrinho vira `convertido`;
- pedido nasce `pendente_pagamento`;
- itens viram snapshot;
- estoque não baixa ainda.

Fluxo:

```text
Carrinho
  ↓
Finalizar pedido
  ↓
shopping_pedido_finalizar_carrinho
  ↓
shopping_pedidos
  ↓
shopping_pedido_itens
  ↓
shopping_carrinhos.status = convertido
```

## Tela: Meus Pedidos

Arquivos principais:

- `frontend/pedidos.html`
- `frontend/features/orders.js`

### Ação: listar pedidos

RPC chamada:

- `shopping_pedidos_cliente_listar`

Tabelas lidas:

- `shopping_pedidos`
- `shopping_pedido_itens`
- `shopping_pagamentos`

Efeitos colaterais:

- nenhum.

### Ação: continuar pagamento

Destino:

- `frontend/checkout.html?pedido=...`

Efeitos colaterais:

- nenhum; a tela apenas leva o cliente para o checkout dedicado.

## Tela: Checkout

Arquivos principais:

- `frontend/checkout.html`
- `frontend/features/checkout.js`
- `frontend/features/payments.js`

### Ação: iniciar pagamento

RPCs chamadas:

- `shopping_pagamento_criar_rpc`
- `shopping_pagamento_processar_rpc`

Tabelas lidas:

- `shopping_pedidos`
- `shopping_pagamentos`
- `shopping_pagamento_mock_config`

Tabelas escritas:

- `shopping_pagamentos`
- `shopping_pagamento_eventos`
- `shopping_pagamento_logs`
- `shopping_email_fila`
- `shopping_pedidos`
- `shopping_produto_variacoes`, somente se aprovado
- `shopping_estoque_movimentos`, somente se aprovado ou revertido
- `shopping_auditoria`

Efeitos colaterais:

- cria tentativa de pagamento;
- aguarda atraso configurado no provider mock;
- processa automaticamente resultado do provider;
- se aprovado, baixa estoque e marca pedido aprovado;
- se recusado, expira ou timeout, não baixa estoque;
- gera eventos, logs e e-mails simulados.

Fluxo:

```text
Meus Pedidos
  ↓
Escolhe Pix/Débito/Crédito
  ↓
shopping_pagamento_criar_rpc
  ↓
shopping_pagamentos
  ↓
Processando pagamento
  ↓
shopping_pagamento_processar_rpc
  ↓
Mock Provider
  ↓
aprovado / recusado / expirado / timeout
```

### Ação: cancelar tentativa de pagamento

RPC/endpoint chamado:

- Mock/local: `shopping_pagamento_cancelar_tentativa_rpc`
- Mercado Pago: `/api/payments/cancel`, que também registra em `shopping_pagamento_cancelar_tentativa_rpc`

Tabelas escritas:

- `shopping_pagamentos`
- `shopping_pagamento_eventos`
- `shopping_pagamento_logs`
- `shopping_auditoria`
- `shopping_pedidos`, mantendo `pagamento_status = pendente`

Efeitos colaterais:

- cancela somente a tentativa atual;
- interrompe o polling;
- mantém o pedido aberto para outro método;
- preserva histórico técnico em pagamentos/eventos/logs.

### Estados exibidos ao cliente

| Estado | Origem SQL | Mensagem esperada |
|---|---|---|
| `pendente` sem pagamento | `shopping_pedidos.pagamento_status` | Escolha a forma de pagamento. |
| processamento | estado visual temporário do frontend | Processando pagamento. |
| `aprovado` | provider confirmou | Pagamento aprovado. |
| `recusado` | provider recusou | Pagamento recusado. |
| `expirado` + Pix | provider expirou | PIX expirado. |
| `pendente` + `mock_timeout` | provider não confirmou | Tempo esgotado no processamento. |

## Tela: Admin - Perfis

Arquivos principais:

- `frontend/admin.html`
- `frontend/features/auth.js`
- `frontend/features/admin.js`

### Ação: listar perfis

RPC chamada:

- `shopping_admin_listar_perfis`

Tabelas lidas:

- `shopping_perfis`

Efeitos colaterais:

- nenhum.

Permissão:

- master ativo.

### Ação: alterar papel

RPC chamada:

- `shopping_admin_definir_papel`

Tabelas lidas/escritas:

- `shopping_perfis`
- `shopping_auditoria`

Efeitos colaterais:

- registra antes/depois;
- exige motivo.

### Ação: alterar status de ativação

RPC chamada:

- `shopping_admin_definir_status_ativacao`

Tabelas alteradas:

- `shopping_perfis`
- `shopping_auditoria`

Efeitos colaterais:

- pode ativar, bloquear ou inativar usuário.

## Tela: Admin - Produtos/Cadastro

Arquivos principais:

- `frontend/admin.html`
- `frontend/features/adminProducts.js`

### Ação: upload de fotos

API usada:

- `supabase.storage.from("shopping-produtos").upload(...)`
- `getPublicUrl(...)`
- `remove(...)` para limpar arquivos quando necessário.

Tabelas/objetos:

- `storage.buckets`
- `storage.objects`
- bucket `shopping-produtos`

Efeitos colaterais:

- cria arquivos públicos controlados por policy admin.

### Ação: salvar produto com estoque

RPC chamada:

- `shopping_admin_salvar_produto_com_estoque`

Tabelas lidas/escritas:

- `shopping_produtos`
- `shopping_produto_imagens`
- `shopping_produto_variacoes`
- `shopping_estoque_movimentos`
- `shopping_auditoria`

Efeitos colaterais:

- cria ou atualiza produto;
- substitui lista de imagens;
- define foto principal;
- cria/atualiza variação principal;
- registra movimento de estoque se houve diferença;
- registra auditoria.

Fluxo:

```text
Admin Cadastro
  ↓
Upload fotos no Storage
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
```

### Ação: listar produtos no admin

RPC chamada:

- `shopping_admin_listar_produtos_com_estoque`

Tabelas lidas:

- `shopping_produtos`
- `shopping_produto_imagens`
- `shopping_produto_variacoes`

Efeitos colaterais:

- nenhum.

### Ação: excluir produto

RPC chamada:

- `shopping_admin_excluir_produto`

Tabelas alteradas:

- `shopping_produtos`
- dependentes por cascade: imagens, variações, movimentos, carrinho itens dependendo da FK
- `shopping_auditoria`

Efeitos colaterais:

- remove registro físico;
- registra auditoria.

Observação:

- em ambiente comercial real, arquivar produto pode ser melhor que excluir.

## Tela: Admin - Pedidos

Arquivos principais:

- `frontend/admin.html`
- `frontend/features/adminOrders.js`

### Ação: listar pedidos recebidos

RPC chamada:

- `shopping_admin_listar_pedidos`

Tabelas lidas:

- `shopping_pedidos`
- `shopping_pedido_itens`
- `shopping_pagamentos`

Efeitos colaterais:

- nenhum.

### Ação: listar pagamentos

RPC chamada:

- `shopping_admin_listar_pagamentos`

Tabelas lidas:

- `shopping_pagamentos`
- `shopping_pedidos`
- `shopping_pagamento_eventos`
- `shopping_email_fila`

Efeitos colaterais:

- nenhum.

Uso:

- permite acompanhar status, método, erro, eventos e e-mails simulados.

## Configuração do Mock Provider

Hoje a configuração é feita por SQL:

```sql
select public.shopping_pagamento_mock_configurar('sempre_aprovar', 3500, 9000, 300000);
select public.shopping_pagamento_mock_configurar('sempre_recusar', 3500, 9000, 300000);
select public.shopping_pagamento_mock_configurar('aleatorio', 3500, 9000, 300000);
select public.shopping_pagamento_mock_configurar('timeout', 3500, 9000, 300000);
select public.shopping_pagamento_mock_configurar('expirar', 3500, 9000, 300000);
```

Tela atual:

- ainda não existe painel visual para configuração.

Tabelas alteradas:

- `shopping_pagamento_mock_config`
- `shopping_auditoria`

Efeitos no cliente:

- `sempre_aprovar`: pagamento aprovado automaticamente.
- `sempre_recusar`: pagamento recusado automaticamente.
- `aleatorio`: provider escolhe entre aprovado, recusado e expirado.
- `timeout`: tentativa fica pendente com erro técnico `mock_timeout`.
- `expirar`: tentativa expira.

## Mapa Rápido de RPCs por Tela

| Tela | Ação | RPC/API | Tabelas principais | Escreve? |
|---|---|---|---|---|
| Login/Header | Carregar perfil | `shopping_perfil_atual` | `shopping_perfis` | Não |
| Admin Perfis | Listar perfis | `shopping_admin_listar_perfis` | `shopping_perfis` | Não |
| Admin Perfis | Alterar papel | `shopping_admin_definir_papel` | `shopping_perfis`, `shopping_auditoria` | Sim |
| Admin Perfis | Alterar status | `shopping_admin_definir_status_ativacao` | `shopping_perfis`, `shopping_auditoria` | Sim |
| Catálogo | Listar produtos | `shopping_catalogo_produtos_publicados_com_estoque` | `shopping_produtos`, `shopping_produto_imagens`, `shopping_produto_variacoes` | Não |
| Produto | Adicionar carrinho | `shopping_carrinho_adicionar_produto` | `shopping_carrinhos`, `shopping_carrinho_itens` | Sim |
| Carrinho | Listar carrinho | `shopping_carrinho_atual` | carrinho, produtos, imagens, variações | Pode criar carrinho |
| Carrinho | Quantidade | `shopping_carrinho_definir_quantidade` | `shopping_carrinho_itens` | Sim |
| Carrinho | Remover | `shopping_carrinho_remover_item` | `shopping_carrinho_itens` | Sim |
| Carrinho | Finalizar | `shopping_pedido_finalizar_carrinho` | pedidos, itens, carrinho | Sim |
| Pedidos | Listar pedidos | `shopping_pedidos_cliente_listar` | pedidos, itens, pagamentos | Não |
| Pedidos | Criar pagamento | `shopping_pagamento_criar_rpc` | pagamentos, eventos, emails, auditoria | Sim |
| Pedidos | Processar pagamento | `shopping_pagamento_processar_rpc` | pagamentos, pedidos, estoque, logs | Sim |
| Admin Produtos | Upload foto | Storage API | `storage.objects` | Sim |
| Admin Produtos | Salvar | `shopping_admin_salvar_produto_com_estoque` | produtos, imagens, variações, estoque | Sim |
| Admin Produtos | Listar | `shopping_admin_listar_produtos_com_estoque` | produtos, imagens, variações | Não |
| Admin Produtos | Excluir | `shopping_admin_excluir_produto` | produtos, auditoria | Sim |
| Admin Pedidos | Listar pedidos | `shopping_admin_listar_pedidos` | pedidos, itens, pagamentos | Não |
| Admin Pagamentos | Listar pagamentos | `shopping_admin_listar_pagamentos` | pagamentos, eventos, emails | Não |

## Efeitos Colaterais Críticos

### Adicionar ao Carrinho

- Pode criar carrinho ativo.
- Valida login.
- Valida estoque.
- Não baixa estoque.

### Finalizar Pedido

- Converte carrinho.
- Cria pedido e snapshots.
- Não baixa estoque.

### Pagamento Aprovado

- Atualiza `shopping_pagamentos.status`.
- Atualiza `shopping_pedidos.pagamento_status`.
- Preenche `pagamento_confirmado_em`.
- Baixa `shopping_produto_variacoes.estoque_atual`.
- Cria `shopping_estoque_movimentos`.
- Cria eventos/logs.
- Enfileira e-mails simulados.

### Pagamento Recusado/Expirado/Timeout

- Atualiza pagamento e pedido.
- Não baixa estoque para pedidos novos.
- Registra evento/log.
- Enfileira e-mails simulados.

## Pontos de Atenção para Desenvolvedores

- Não chamar `shopping_pagamento_mock_simular` diretamente do frontend; ela é interna do Mock Provider.
- O frontend deve usar `shopping_pagamento_criar_rpc` e `shopping_pagamento_processar_rpc`.
- Não voltar a baixar estoque na finalização do pedido.
- Não escrever direto em `shopping_pedidos`, `shopping_pagamentos` ou `shopping_estoque_movimentos` pelo frontend.
- Para imagem de produto, usar Storage e salvar URLs em `shopping_produto_imagens`.
- Para catálogo, a RPC principal é `shopping_catalogo_produtos_publicados_com_estoque`.
- Para admin de produtos, a RPC principal é `shopping_admin_salvar_produto_com_estoque`.

## Fluxo de Diagnóstico

### Produto não aparece no catálogo

Verificar:

```text
shopping_produtos.status = publicado
  ↓
shopping_produto_variacoes.ativo = true
  ↓
shopping_produto_variacoes.estoque_atual
  ↓
shopping_produto_imagens
  ↓
shopping_catalogo_produtos_publicados_com_estoque
```

### Pedido não baixa estoque

Verificar:

```text
shopping_pagamentos.status
  ↓
shopping_pedidos.pagamento_status
  ↓
shopping_pedidos.estoque_baixado_em
  ↓
shopping_estoque_movimentos
  ↓
shopping_pagamento_logs
```

### Pagamento não processa

Verificar:

```text
shopping_pagamento_criar_rpc existe
  ↓
shopping_pagamento_processar_rpc existe
  ↓
shopping_pagamento_mock_config
  ↓
shopping_pagamento_eventos
  ↓
shopping_pagamento_logs
```

### Admin não acessa

Verificar:

```text
auth.uid()
  ↓
shopping_perfis.user_id
  ↓
papel in master/funcionario/parceiro
  ↓
status_ativacao = ativo
  ↓
shopping_is_admin
```
