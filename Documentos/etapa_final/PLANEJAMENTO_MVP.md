# PLANEJAMENTO_MVP.md

# Planejamento MVP - IAGO Shopping

Documento de retomada atualizado para foco no fechamento da Fase 9B.

---

## Objetivo do MVP

Construir o IAGO Shopping como uma plataforma completa de e-commerce para a comunidade do skate, com:

- catalogo publico;
- autenticacao Supabase;
- perfis por papel;
- administracao progressiva;
- cadastro de produtos;
- estoque por variacao;
- carrinho;
- pedidos;
- pagamentos;
- dashboards;
- integracao futura e segura com a Pesquisa IAGO.

O MVP deve manter a Pesquisa IAGO separada do Shopping e usar integracao futura apenas por `response_id` e consentimento.

---

## Status Geral das Fases

| Fase | Nome | Status |
| --- | --- | --- |
| 0 | Infraestrutura Frontend | Concluida |
| 1 | Estrutura SQL, RLS e Perfis | Concluida |
| 2 | Supabase Auth | Concluida |
| 3 | Administracao e Permissoes | Base implementada |
| 4 | Catalogo Comercial | Base implementada |
| 5 | Cadastro de Produtos | Base implementada |
| 6 | Estoque | Base implementada |
| 7 | Carrinho | Base implementada |
| 8 | Pedidos | Base implementada |
| 9 | Pagamentos | Em fechamento |
| 9A | Mercado Pago Sandbox | Implementada, pendente validacao final |
| 9B | Cancelamento e estabilizacao de pagamentos | Fase atual |
| 10 | Dashboard Administrativo | Nao iniciar agora |
| 11 | Integracao Pesquisa IAGO | Nao iniciar agora |

---

## Fase Atual

```text
Fase 9B - Fechamento da etapa de Pagamentos
```

Objetivo:

Finalizar 100% o fluxo de pagamento antes de iniciar Usuarios, Perfis, Area Administrativa ou qualquer novo modulo.

Escopo:

- Pix;
- Cartao de Debito;
- Cartao de Credito;
- Mercado Pago;
- Payment Brick;
- webhook;
- sincronizacao;
- cancelamento;
- expiracao;
- nova tentativa;
- historico;
- preparacao Sandbox/Producao por configuracao.

---

## Entregas da Fase 9B

### 1. Cancelamento do Pix

Corrigir a exibicao inconsistente do botao de cancelamento.

Enquanto o Pix estiver em estado de espera, o usuario deve ver a acao para cancelar Pix.

Estados de espera incluem:

- pendente;
- aguardando pagamento;
- aguardando QR;
- tentativa criada sem status final.

Ao cancelar:

- cancelar no Mercado Pago quando houver `provider_payment_id`;
- cancelar no banco via RPC;
- atualizar Supabase;
- liberar imediatamente nova tentativa;
- atualizar a tela sem reload manual.

### 2. QR Code Pix

Investigar por que a interface mostra apenas:

```text
Aguardando codigo Pix do provider.
```

Validar:

- payload enviado ao backend;
- request enviada ao Mercado Pago;
- response recebida;
- `qr_code`;
- `qr_code_base64`;
- `qr_code_url`;
- `copia_cola`;
- mapeamento backend;
- mapeamento RPC;
- mapeamento frontend.

Caso exista erro, mostrar a origem real sem mascarar:

- Mercado Pago;
- backend;
- Supabase RPC;
- frontend;
- limitacao do Sandbox.

### 3. Sandbox Mercado Pago

Confirmar e documentar se o Sandbox atual gera:

- QR Code Pix;
- Copia e Cola;
- status pendente;
- aprovacao;
- recusa;
- expiracao;
- cancelamento.

Se houver limitacao do Sandbox, documentar claramente.

### 4. Producao

Preparar documentacao para troca por configuracao, sem alterar codigo:

- quais variaveis trocar;
- onde trocar;
- como mudar Sandbox para Producao;
- como voltar para Sandbox;
- como validar webhook;
- quais cuidados tomar com credenciais.

### 5. Fluxo Completo Aprovado

Validar:

```text
Pedido criado
Pagamento criado
QR gerado
Pagamento pendente
Pagamento aprovado
Pedido confirmado
Baixa de estoque
Historico atualizado
Tela final
```

### 6. Fluxo Recusado

Validar:

```text
Pedido criado
Pagamento recusado
Permitir nova tentativa
Sem criar pedido duplicado
Mesmo pedido continua
Nova tentativa reutiliza o pedido
```

### 7. Fluxo Cancelado

Validar:

```text
Cancelar Pix
Cancelar Mercado Pago
Cancelar Supabase
Liberar nova tentativa
Continuar checkout
```

### 8. Fluxo Expirado

Validar:

```text
Expirar Pix
Atualizar automaticamente
Mostrar Pix expirado
Permitir gerar novo Pix
Sem atualizar pagina
```

### 9. Payment Brick

Revisar tema visual do Payment Brick.

Campos como numero do cartao, validade e CVV devem seguir o visual escuro do IAGO Shopping sempre que o SDK permitir.

Nao deixar inputs brancos se houver suporte de tema ou customizacao.

Se o SDK limitar alguma parte, registrar exatamente qual componente nao pode ser customizado.

### 10. Alinhamento Visual do Checkout

Centralizar e padronizar as etapas superiores:

- Pedido criado;
- Pagamento gerado;
- Aguardando pagamento;
- Pagamento confirmado;
- Pedido confirmado.

As etapas devem ter:

- mesmo tamanho;
- mesmo alinhamento;
- mesmo espacamento;
- leitura consistente em desktop e mobile.

### 11. Revisao Geral do Checkout

Revisar apenas o checkout de pagamento procurando:

- bugs pequenos;
- estados inconsistentes;
- textos confusos;
- botoes indevidos;
- loading travado;
- polling;
- atualizacao de tela;
- UX do pagamento.

Nao adicionar funcionalidades novas.

---

## Arquivos Autorizados Para Alteracao

Frontend:

- `frontend/checkout.html`
- `frontend/features/checkout.js`
- `frontend/features/payments.js`
- `frontend/features/orders.js`
- `frontend/css/style.css`

Backend:

- `backend/services/mercado_pago.py`
- `backend/services/payment_engine.py`
- `backend/routers/payments.py`
- `backend/schemas/payments.py`

Evitar qualquer outro arquivo.

Se outro arquivo for inevitavel, explicar o motivo antes de alterar.

---

## Criterio de Encerramento da Fase 9B

A fase so pode ser encerrada sem pendencias conhecidas quando estes itens estiverem funcionando ou documentados com limitacao externa:

- Pix;
- Cancelamento Pix;
- Novo Pix;
- Expiracao;
- Aprovacao;
- Recusa;
- Cartao de Debito;
- Cartao de Credito;
- Payment Brick em tema escuro;
- Producao preparada;
- Homologacao validada;
- fluxo visual alinhado;
- historico atualizado;
- pedido sem duplicacao indevida;
- erros reais visiveis quando houver falha externa.

---

## Proximos Passos Depois da Fase 9B

Somente depois da aprovacao da Fase 9B:

1. iniciar Usuarios, Perfis e Controle de Acesso;
2. revisar Area Administrativa se solicitado;
3. seguir para Dashboard Administrativo;
4. tratar Integracao Pesquisa IAGO por `response_id` e consentimento.

Nao iniciar esses passos durante a Fase 9B.
