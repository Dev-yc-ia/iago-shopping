# Planejamento MVP Atualizado - IAGO Shopping

Documento de retomada para continuar o IAGO Shopping a partir do estado local atual.

## Objetivo

Construir o IAGO Shopping como uma aplicação comercial separada da Pesquisa IAGO, com catálogo público, entrada/login, cadastro/convites, perfis por papel e administração progressiva. O MVP deve permitir evolução para Supabase Auth, catálogo real, estoque por variação, convites vindos da Pesquisa e dashboards, sem copiar dados pessoais da Pesquisa para o Shopping sem necessidade e consentimento.

## Status Atual

Fase 0 concluída localmente:

- entrada obrigatória antes do catálogo;
- opção inequívoca `Continuar sem login`;
- catálogo público mock com filtros e produtos demonstrativos;
- categorias mock incluindo shapes, rodas, tênis e roupas/camisas;
- página de produto com atributos modulares por categoria, sem usar P/M/G universal;
- tela de login e página admin apenas estruturais;
- identidade visual IAGO preservada em tema escuro fixo;
- imagem institucional real em `frontend/assets/images/hero/tela_login.png`;
- hero renderizado como `<img class="hero-scene-image">`, sem alterar pixels da foto;
- navegação local validada em `http://127.0.0.1:8010/`;
- FastAPI mínimo com `/health`, `/api/health` e `/docs`.

## Execução Local

O projeto roda localmente em:

```text
http://127.0.0.1:8010
```

Atalhos principais:

- `instalar.bat`: instala dependências sem exigir ativação manual de ambiente virtual.
- `iniciar.bat`: inicia a API e abre o Shopping.
- `testar.bat`: compila Python e executa testes.

Comportamento atual do `iniciar.bat`:

- usa host fixo `127.0.0.1`;
- usa porta exclusiva `8010`;
- encerra somente processos que estejam escutando a porta `8010`;
- não toca na porta `8000` e não interfere no Hub Operacional IAGO;
- usa `.venv\Scripts\python.exe` quando existir;
- faz fallback para `py` e depois `python`;
- inicia `uvicorn backend.main:app --host 127.0.0.1 --port 8010 --reload`;
- aguarda `http://127.0.0.1:8010/health` responder antes de abrir o navegador;
- tenta abrir Chrome nos locais padrão;
- usa perfil temporário isolado em `%TEMP%\IAGO_Shopping_Chrome_Profile_8010`;
- se esse perfil estiver em uso por uma janela antiga, cria outro perfil limpo com o mesmo prefixo;
- abre Chrome com `--user-data-dir`, cache reduzido/desativado e nova janela;
- se Chrome não existir, abre a URL no navegador padrão.

## Arquivos Relevantes Para Ajuste Manual Visual

Não mexer no layout sem uma solicitação explícita. O layout atual foi aprovado.

Arquivos:

- `frontend/index.html`
- `frontend/login.html`
- `frontend/css/style.css`
- `frontend/assets/images/hero/tela_login.png`

Seletores principais em `frontend/css/style.css`:

- `.entry-hero`, `.auth-main`: canvas/hero da tela de entrada.
- `.hero-scene-image`: imagem institucional real.
- `.onboarding-card`: cartão de login/entrada.
- `.entry-actions`: botões `Continuar com Google` e `Continuar sem login`.
- `.future-auth-row`: links e texto `Criar conta` / Facebook futuro.
- `.brand-logo`, `.brand-product`: marca do cabeçalho.

Estado visual aprovado:

- `tela_login.png` deve continuar como `<img>`, não como `background-image`;
- `.hero-scene-image` deve preservar a foto com `object-fit: contain`;
- não aplicar `cover`, crop, blur, filtro, opacidade ou overlay global sobre a foto;
- o espaço externo à imagem pode usar o fundo escuro do site;
- o cartão pode se sobrepor como objeto controlado pelo site, mas sem alterar pixels da foto;
- manter `filter: none`, `opacity: 1`, `object-position: center center`;
- o cartão deve caber inteiro no hero, incluindo `Criar conta` e o texto de Facebook futuro.

Alerta sobre `contain` x `cover`:

- `contain` preserva a imagem inteira e foi a decisão final aprovada.
- `cover` integra a foto como fundo cheio, mas recorta a imagem quadrada em telas largas e pode cortar o logo IAGO da foto.
- Não voltar para `cover` sem nova decisão explícita do usuário.

## Fase 1 Preparada, Não Aplicada

A Fase 1 está preparada como SQL e documentação revisáveis, mas não foi aplicada no Supabase de produção.

Arquivos:

- `sql/migrations/20260827_001_fase1_perfis_convites_rls.sql`
- `sql/bootstrap/bootstrap_primeiro_master.sql`
- `Documentos/fase1_bootstrap_supabase.md`

Estrutura planejada:

- `public.shopping_perfis`;
- `public.shopping_convites`;
- `public.shopping_auditoria`;
- enums de papel/status/origem;
- RLS de menor privilégio;
- função `public.shopping_is_master`;
- função `public.shopping_bootstrap_primeiro_master`;
- função administrativa de mudança de papel;
- função administrativa de escopos.

Decisões:

- senhas ficam somente no Supabase Auth;
- o Shopping não implementa senha própria;
- master não pode ser promovido pela interface comum;
- o primeiro master deve ser definido por SQL controlado depois que a conta já existir em `auth.users`;
- cliente lê/edita somente perfil limitado;
- funcionário/parceiro não altera papel;
- master controla papéis e escopos por função administrativa segura.

Para bootstrap do primeiro master, o usuário precisará informar:

- UUID da conta criada em `auth.users.id`;
- e-mail normalizado dessa conta;
- nome de exibição.

## Integração Segura Com Pesquisa IAGO

O Shopping é uma aplicação/banco lógico separado da Pesquisa. A integração futura deve referenciar a Pesquisa somente por `response_id`.

Não copiar respostas individuais da Pesquisa para o Shopping. Não copiar dados pessoais sem necessidade. Consultas de elegibilidade devem acontecer em função segura no banco, nunca no navegador.

Esquema conhecido de `contatos_pesquisa`:

```sql
id bigint
response_id uuid
nome text
email text
telefone text
instagram text
data_nascimento date
autorizou_contato boolean
criado_em timestamptz
```

Não registrar valores, nomes de pessoas ou contatos reais neste documento.

Exportação agregada útil da Pesquisa:

- 6 respostas concluídas;
- 417 itens;
- 72 tempos de seção;
- 6 consentimentos.

Elegibilidade comercial futura:

- exigir `contatos_pesquisa.autorizou_contato = true`;
- exigir Q70 com autorização explícita para ofertas comerciais;
- executar essa validação em função segura;
- retornar somente o mínimo necessário para convite/elegibilidade;
- aniversário fica para fase futura e precisa de autorização separada.

## Próximos Passos Ordenados

1. Revisar a migração SQL da Fase 1.
2. Aplicar `sql/migrations/20260827_001_fase1_perfis_convites_rls.sql` no SQL Editor do Supabase do Shopping.
3. Criar a primeira conta no Supabase Auth.
4. Coletar `auth.users.id`, e-mail normalizado e nome de exibição da primeira conta.
5. Ajustar e executar `sql/bootstrap/bootstrap_primeiro_master.sql` no SQL Editor.
6. Integrar login Supabase no frontend, mantendo `Continuar sem login`.
7. Criar fluxo de cadastro direto de cliente.
8. Criar fluxo de convites idempotentes sem token em texto.
9. Implementar catálogo real e admin inicial.
10. Implementar estoque exato por variação.
11. Registrar interesse em produtos esgotados.
12. Criar dashboard agregado, sem expor dados pessoais desnecessários.
13. Criar integração segura com Pesquisa via `response_id` e consentimento.

## Decisões de Privacidade

- Não versionar segredos.
- `.env.example` deve conter apenas exemplos não sensíveis.
- Senhas pertencem ao Supabase Auth.
- Convites não devem guardar tokens em texto.
- Pesquisa só é referenciada por `response_id`.
- Não copiar respostas individuais da Pesquisa para o Shopping.
- Elegibilidade comercial exige consentimento em `autorizou_contato` e autorização explícita na Q70.
- Dados agregados podem orientar dashboard, mas sem nomes, contatos ou respostas pessoais.
- Aniversário depende de autorização separada em fase futura.

## O Que Não Foi Feito

- Supabase não foi conectado pela aplicação local.
- Migração da Fase 1 não foi aplicada no banco remoto.
- Nenhum segredo foi criado ou versionado.
- Autenticação real não foi implementada.
- Upload e pagamento não foram implementados.
- Catálogo real e estoque persistido foram preparados localmente e dependem da aplicação da migration da Fase 6 no Supabase.
- Não foram copiados módulos funcionais do Hub, como terminal, mapa, SQL View ou pipelines.
- Não foi alterado o Hub Operacional IAGO.
- Não foram copiados dados pessoais da Pesquisa.

## Verificações Recentes

- `http://127.0.0.1:8010/health` respondeu `200` com app `IAGO Shopping`.
- `http://127.0.0.1:8010/api/health` respondeu `200`.
- `http://127.0.0.1:8010/` respondeu `200` com título `IAGO Shopping`.
- `python -m pytest` passou com 4 testes.
- Aviso conhecido: `pytest` pode não conseguir gravar `.pytest_cache` por permissão no ambiente local.

## Retomada Recomendada

Ao retomar, começar por:

1. abrir `README.md`;
2. abrir este documento;
3. executar `iniciar.bat`;
4. confirmar `http://127.0.0.1:8010/health`;
5. revisar a migração SQL antes de qualquer ação no Supabase.

## Estado das fases

Última atualização: 29/08/2026

| Fase | Nome | Status |
|---:|---|---|
| 0 | Infraestrutura Frontend | Concluída |
| 1 | Estrutura SQL, RLS e Perfis | Concluída |
| 2 | Supabase Auth | Concluída |
| 3 | Administração e Permissões | Concluída |
| 4 | Catálogo Comercial | Concluída |
| 5 | Cadastro de Produtos | Concluída localmente |
| Extra | Recuperação de Senha | Concluída localmente |
| 6 | Estoque | Concluída localmente |
| 7 | Carrinho | Concluída localmente |
| 8 | Pedidos | Concluída |
| 9 | Pagamentos | Concluída localmente |
| 10 | Dashboard Administrativo | Não iniciada |
| 11 | Integração Pesquisa IAGO | Não iniciada |

### Ajuste Fase 5 - Cadastro MVP simplificado

- Painel administrativo simplificado para manter apenas SKU, nome, marca, categoria, preço, status, descrição e foto principal.
- Foto Principal usa seleção local por arquivo com pré-visualização antes do salvamento.
- Código preparado para integração futura com Supabase Storage, sem salvar imagens na pasta do projeto.
- Prévia do card do produto atualizada em tempo real conforme o cadastro é preenchido.

### Fase 6 - Estoque por variação

- Migration `sql/migrations/20260828_004_fase6_estoque.sql` criada para estoque por variação, saldo atual e histórico de movimentações.
- Migration `sql/migrations/20260828_005_fase6_storage_fotos_produtos.sql` criada para bucket público e políticas de upload das fotos de produtos.
- Cadastro administrativo passa a lançar a quantidade de estoque junto com o produto.
- Foto principal passa a ser enviada ao Supabase Storage e a URL pública fica vinculada ao produto.
- Catálogo comercial passa a consumir produtos publicados do Supabase com estoque real.
- Produtos com estoque maior que zero aparecem como disponíveis; estoque zero aparece como esgotado.
- Carrinho, pedidos, pagamentos e baixa automática por venda permanecem fora desta fase.

### Fase 7 - Carrinho por perfil autenticado

- Migration `sql/migrations/20260828_006_fase7_carrinho.sql` criada para carrinho ativo por usuário autenticado.
- Carrinho e itens ficam vinculados ao `auth.uid()` via `shopping_carrinhos.user_id`.
- Visitantes não conseguem montar carrinho; ao tentar adicionar produto, são enviados ao login com aviso claro.
- Menu exibe `Carrinho` apenas quando existe sessão autenticada.
- Página `frontend/carrinho.html` lista itens do carrinho ativo, permite aumentar, reduzir e remover produtos.
- Adição ao carrinho valida produto publicado e estoque disponível, mas não baixa estoque nesta fase.
- Pedidos, pagamentos e conversão do carrinho permanecem fora da Fase 7.

### Fase 8 - Pedidos

- Migration `sql/migrations/20260828_007_fase8_pedidos.sql` criada para pedidos e itens do pedido.
- Carrinho ativo pode ser finalizado em pedido com status inicial `pendente_pagamento`.
- Itens do pedido guardam snapshot de SKU, nome, marca, categoria, foto, preço e quantidade.
- Finalização do pedido foi entregue inicialmente com baixa de estoque; na Fase 9, a baixa definitiva passa a ocorrer somente após pagamento aprovado.
- Cliente logado passa a acessar `frontend/pedidos.html` para acompanhar seus pedidos.
- Painel administrativo passa a listar pedidos recebidos para acompanhamento operacional.
- Pagamentos, gateway, Pix e cartão permanecem fora da Fase 8.

### Fase 9 - Pagamentos

- Migration `sql/migrations/20260828_008_fase9_pagamentos.sql` criada para Payment Engine em modo Mock.
- Migration `sql/migrations/20260829_010_fase9_pagamentos_mock_automatico.sql` criada para fluxo automatico semelhante a producao.
- Migration `sql/migrations/20260829_011_fase9a_mercado_pago_sandbox.sql` criada para campos oficiais de provider, Mercado Pago Sandbox, Pix, webhook, consulta, auditoria e sincronizacao.
- Migration `sql/migrations/20260829_012_fase9b_cancelamento_pagamento.sql` criada para cancelamento de tentativa sem cancelar pedido.
- Pedido continua sendo criado a partir do carrinho, mas estoque só baixa após confirmação de pagamento aprovado.
- Pagamentos mock processam automaticamente status `aprovado`, `recusado`, `pendente` por timeout e `expirado`.
- Tabelas de pagamentos, eventos, logs e fila de e-mails simulada foram criadas.
- Cliente escolhe Pix, cartão de débito ou cartão de crédito e inicia o pagamento em `frontend/checkout.html`.
- Botões manuais de aprovação/recusa foram removidos do fluxo do cliente.
- Mock Provider pode ser configurado para `sempre_aprovar`, `sempre_recusar`, `aleatorio`, `timeout` ou `expirar`.
- Mercado Pago Sandbox foi acoplado ao Payment Engine via backend, mantendo credenciais no `.env` e estado/auditoria no Supabase.
- Pix passa a ter suporte a QR Code oficial, copia e cola, expiração e sincronização automática.
- Cartões ficam preparados para Mercado Pago Payment Brick com tokenização no frontend e criação do pagamento pelo backend.
- Webhook Mercado Pago fica preparado para confirmar pagamento automaticamente e disparar as mesmas regras de estoque, evento, log e e-mail.
- Fase 9B criou `frontend/checkout.html` como tela dedicada para pagamento profissional.
- Carrinho passa a finalizar pedido e seguir para `checkout.html?pedido=...`.
- `frontend/pedidos.html` continua como histórico/acompanhamento e oferece caminho para continuar pagamento.
- Checkout exibe resumo do pedido, itens, etapa atual, métodos Pix/débito/crédito, QR Pix, copia e cola, contagem de expiração, atualização de status e Payment Brick com tema escuro IAGO.
- Cliente pode cancelar a tentativa de pagamento ativa; o pedido permanece pendente e liberado para outro método.
- Painel administrativo passa a acompanhar pedidos e tentativas de pagamento.
- Backend recebeu provider desacoplado com Mock ativo e Mercado Pago Sandbox/produção selecionável por configuração.
- Checklist completo em `Documentos/CHECKLIST_TESTES_FASE9_PAGAMENTOS.md`.
