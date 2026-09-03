# IAGO Shopping - Bootstrap Supabase Fase 1

Este documento prepara a Fase 1 sem conectar ou alterar o Supabase de produção automaticamente.

## Ordem de Execução

1. Criar ou confirmar a conta do primeiro master no Supabase Auth.
2. Copiar o UUID dessa conta em `auth.users.id`.
3. Executar no SQL Editor a migração:

```text
sql/migrations/20260827_001_fase1_perfis_convites_rls.sql
```

4. Executar no SQL Editor o bootstrap:

```text
sql/bootstrap/bootstrap_primeiro_master.sql
```

5. Substituir os placeholders do bootstrap antes de executar.

## Dados Que o Usuário Precisa Informar

- UUID da conta já criada no Supabase Auth: `auth.users.id`.
- E-mail normalizado dessa conta, em minúsculas.
- Nome de exibição desejado para o master.

Exemplo de formato:

```text
UUID: 00000000-0000-0000-0000-000000000000
E-mail: nome@dominio.com
Nome: Nome Sobrenome
```

Não informar senha em SQL. Senhas ficam somente no Supabase Auth.

## Separação Shopping x Pesquisa

O Shopping é uma aplicação e banco lógico separado da Pesquisa.

A única referência prevista nesta preparação é `response_id`, armazenada em `public.shopping_perfis.response_id` e `public.shopping_convites.response_id`.

Não copiar respostas individuais da Pesquisa para o Shopping.

## Elegibilidade Futura Pela Pesquisa

A elegibilidade futura para convites comerciais deve exigir, no mínimo:

- `contatos_pesquisa.autorizou_contato = true`;
- resposta Q70 contendo autorização explícita para ofertas comerciais.

Essa verificação deve ocorrer em função segura no banco, nunca no navegador. A função deve retornar apenas elegibilidade e motivo operacional, sem expor respostas individuais da Pesquisa ao frontend.

Aniversário fica fora desta fase e exigirá autorização separada.

## Primeiro Master

O primeiro master deve ser definido somente por SQL controlado depois que o usuário tiver criado a conta ou feito login no Supabase Auth.

A função `public.shopping_bootstrap_primeiro_master(...)` não é concedida a `authenticated`, `anon` ou `public`. Ela foi desenhada para uso administrativo no SQL Editor.

Depois do primeiro master ativo, mudanças de papel devem usar:

```sql
select public.shopping_admin_definir_papel(
  p_user_id := '<uuid_do_usuario_alvo>'::uuid,
  p_papel := 'parceiro'::public.shopping_papel,
  p_motivo := 'Motivo auditável da alteração'
);
```

A função exige master ativo, grava auditoria e não permite alteração do próprio papel por ela.

## RLS

Princípios aplicados:

- usuário autenticado lê apenas o próprio perfil;
- usuário autenticado edita apenas campos limitados do próprio perfil;
- usuário comum não altera `user_id`, `response_id`, `origem`, `papel`, `escopos` ou status administrativo;
- funcionário e parceiro não conseguem promover papel pela interface;
- convites e auditoria ficam restritos a master;
- funções administrativas exigem master ativo e motivo auditável.

## Convites

`public.shopping_convites` armazena:

- contato normalizado opcional;
- hash do contato;
- hash do convite;
- status do convite;
- papel de destino não master;
- vínculo opcional por `response_id`.

Tokens reais de convite não devem ser persistidos em texto aberto.
