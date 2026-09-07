-- IAGO Shopping - WEB-02
-- Menu do usuario, avatar, dados pessoais, endereco padrao e preferencia de pagamento.
--
-- Escopo:
-- - reaproveita shopping_perfis como cadastro 1:1 do usuario;
-- - cria shopping_enderecos para endereco padrao de entrega;
-- - adiciona RPCs de autosservico sem permitir alteracao de papel/status/escopos;
-- - cria bucket privado shopping-avatars com isolamento por pasta do proprio UID;
-- - nao armazena dados brutos de cartao.

alter table public.shopping_perfis
  add column if not exists nome_completo text,
  add column if not exists avatar_path text,
  add column if not exists pagamento_preferido text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'shopping_perfis_pagamento_preferido_valido'
      and conrelid = 'public.shopping_perfis'::regclass
  ) then
    alter table public.shopping_perfis
      add constraint shopping_perfis_pagamento_preferido_valido
      check (
        pagamento_preferido is null
        or pagamento_preferido in ('pix', 'cartao_debito', 'cartao_credito')
      );
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'shopping_perfis_nome_completo_not_blank'
      and conrelid = 'public.shopping_perfis'::regclass
  ) then
    alter table public.shopping_perfis
      add constraint shopping_perfis_nome_completo_not_blank
      check (nome_completo is null or btrim(nome_completo) <> '');
  end if;
end
$$;

create table if not exists public.shopping_enderecos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  nome_destinatario text,
  cep text,
  logradouro text,
  numero text,
  complemento text,
  bairro text,
  cidade text,
  uf text,
  referencia text,
  padrao boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_enderecos_user_id_not_null check (user_id is not null),
  constraint shopping_enderecos_uf_valida check (uf is null or char_length(btrim(uf)) = 2)
);

create index if not exists idx_shopping_enderecos_user_id
  on public.shopping_enderecos (user_id);

create unique index if not exists idx_shopping_enderecos_um_padrao_por_user
  on public.shopping_enderecos (user_id)
  where padrao;

drop trigger if exists trg_shopping_enderecos_touch on public.shopping_enderecos;
create trigger trg_shopping_enderecos_touch
before update on public.shopping_enderecos
for each row execute function public.shopping_touch_atualizado_em();

alter table public.shopping_enderecos enable row level security;

drop policy if exists shopping_enderecos_select_self on public.shopping_enderecos;
create policy shopping_enderecos_select_self
on public.shopping_enderecos
for select
to authenticated
using (user_id = auth.uid());

drop policy if exists shopping_enderecos_insert_self on public.shopping_enderecos;
create policy shopping_enderecos_insert_self
on public.shopping_enderecos
for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists shopping_enderecos_update_self on public.shopping_enderecos;
create policy shopping_enderecos_update_self
on public.shopping_enderecos
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists shopping_enderecos_delete_self on public.shopping_enderecos;
create policy shopping_enderecos_delete_self
on public.shopping_enderecos
for delete
to authenticated
using (user_id = auth.uid());

revoke all on public.shopping_enderecos from anon, authenticated;
grant select, insert, update, delete on public.shopping_enderecos to authenticated;

drop function if exists public.shopping_perfil_atual();
create function public.shopping_perfil_atual()
returns table (
  user_id uuid,
  nome_exibicao text,
  nome_completo text,
  email_normalizado text,
  telefone_normalizado text,
  avatar_path text,
  pagamento_preferido text,
  papel public.shopping_papel,
  escopos jsonb,
  status_convite public.shopping_status_convite,
  status_ativacao public.shopping_status_ativacao,
  origem public.shopping_origem_perfil,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  return query
  select
    sp.user_id,
    sp.nome_exibicao,
    sp.nome_completo,
    sp.email_normalizado,
    sp.telefone_normalizado,
    sp.avatar_path,
    sp.pagamento_preferido,
    sp.papel,
    sp.escopos,
    sp.status_convite,
    sp.status_ativacao,
    sp.origem,
    sp.criado_em,
    sp.atualizado_em
  from public.shopping_perfis sp
  where sp.user_id = auth.uid();
end;
$$;

create or replace function public.shopping_perfil_pessoal_salvar(
  p_nome_completo text default null,
  p_telefone_normalizado text default null,
  p_avatar_path text default null,
  p_pagamento_preferido text default null
)
returns table (
  user_id uuid,
  nome_exibicao text,
  nome_completo text,
  email_normalizado text,
  telefone_normalizado text,
  avatar_path text,
  pagamento_preferido text,
  papel public.shopping_papel,
  escopos jsonb,
  status_convite public.shopping_status_convite,
  status_ativacao public.shopping_status_ativacao,
  origem public.shopping_origem_perfil,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_perfil public.shopping_perfis;
begin
  if v_actor is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  if p_pagamento_preferido is not null
    and p_pagamento_preferido not in ('pix', 'cartao_debito', 'cartao_credito') then
    raise exception 'Preferencia de pagamento invalida.';
  end if;

  if p_avatar_path is not null
    and split_part(p_avatar_path, '/', 1) <> v_actor::text then
    raise exception 'Avatar deve ficar na pasta do proprio usuario.';
  end if;

  update public.shopping_perfis
  set nome_completo = nullif(btrim(p_nome_completo), ''),
      telefone_normalizado = nullif(btrim(p_telefone_normalizado), ''),
      avatar_path = nullif(btrim(p_avatar_path), ''),
      pagamento_preferido = p_pagamento_preferido,
      atualizado_por = v_actor
  where public.shopping_perfis.user_id = v_actor
  returning * into v_perfil;

  if v_perfil.id is null then
    raise exception 'Perfil do usuario autenticado nao encontrado.';
  end if;

  insert into public.shopping_auditoria (
    ator_user_id,
    acao,
    tabela,
    registro_id,
    depois,
    motivo
  )
  values (
    v_actor,
    'perfil.dados_pessoais_atualizados',
    'shopping_perfis',
    v_perfil.id,
    jsonb_build_object(
      'nome_completo_informado', v_perfil.nome_completo is not null,
      'telefone_informado', v_perfil.telefone_normalizado is not null,
      'avatar_informado', v_perfil.avatar_path is not null,
      'pagamento_preferido', v_perfil.pagamento_preferido
    ),
    'Atualizacao de autosservico pela pagina /dados-pessoais/.'
  );

  return query
  select *
  from public.shopping_perfil_atual();
end;
$$;

create or replace function public.shopping_endereco_padrao_atual()
returns table (
  id uuid,
  user_id uuid,
  nome_destinatario text,
  cep text,
  logradouro text,
  numero text,
  complemento text,
  bairro text,
  cidade text,
  uf text,
  referencia text,
  padrao boolean,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  return query
  select
    se.id,
    se.user_id,
    se.nome_destinatario,
    se.cep,
    se.logradouro,
    se.numero,
    se.complemento,
    se.bairro,
    se.cidade,
    se.uf,
    se.referencia,
    se.padrao,
    se.criado_em,
    se.atualizado_em
  from public.shopping_enderecos se
  where se.user_id = auth.uid()
    and se.padrao is true
  order by se.atualizado_em desc
  limit 1;
end;
$$;

create or replace function public.shopping_endereco_padrao_salvar(
  p_nome_destinatario text default null,
  p_cep text default null,
  p_logradouro text default null,
  p_numero text default null,
  p_complemento text default null,
  p_bairro text default null,
  p_cidade text default null,
  p_uf text default null,
  p_referencia text default null
)
returns table (
  id uuid,
  user_id uuid,
  nome_destinatario text,
  cep text,
  logradouro text,
  numero text,
  complemento text,
  bairro text,
  cidade text,
  uf text,
  referencia text,
  padrao boolean,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_endereco_id uuid;
  v_endereco public.shopping_enderecos;
begin
  if v_actor is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  if p_uf is not null and char_length(btrim(p_uf)) <> 2 then
    raise exception 'UF deve conter 2 caracteres.';
  end if;

  select se.id
  into v_endereco_id
  from public.shopping_enderecos se
  where se.user_id = v_actor
    and se.padrao is true
  order by se.atualizado_em desc
  limit 1
  for update;

  if v_endereco_id is null then
    insert into public.shopping_enderecos (
      user_id,
      nome_destinatario,
      cep,
      logradouro,
      numero,
      complemento,
      bairro,
      cidade,
      uf,
      referencia,
      padrao
    )
    values (
      v_actor,
      nullif(btrim(p_nome_destinatario), ''),
      nullif(btrim(p_cep), ''),
      nullif(btrim(p_logradouro), ''),
      nullif(btrim(p_numero), ''),
      nullif(btrim(p_complemento), ''),
      nullif(btrim(p_bairro), ''),
      nullif(btrim(p_cidade), ''),
      upper(nullif(btrim(p_uf), '')),
      nullif(btrim(p_referencia), ''),
      true
    )
    returning * into v_endereco;
  else
    update public.shopping_enderecos
    set nome_destinatario = nullif(btrim(p_nome_destinatario), ''),
        cep = nullif(btrim(p_cep), ''),
        logradouro = nullif(btrim(p_logradouro), ''),
        numero = nullif(btrim(p_numero), ''),
        complemento = nullif(btrim(p_complemento), ''),
        bairro = nullif(btrim(p_bairro), ''),
        cidade = nullif(btrim(p_cidade), ''),
        uf = upper(nullif(btrim(p_uf), '')),
        referencia = nullif(btrim(p_referencia), ''),
        padrao = true
    where public.shopping_enderecos.id = v_endereco_id
      and public.shopping_enderecos.user_id = v_actor
    returning * into v_endereco;
  end if;

  insert into public.shopping_auditoria (
    ator_user_id,
    acao,
    tabela,
    registro_id,
    depois,
    motivo
  )
  values (
    v_actor,
    'endereco.padrao_atualizado',
    'shopping_enderecos',
    v_endereco.id,
    jsonb_build_object(
      'endereco_informado', (
        v_endereco.cep is not null
        or v_endereco.logradouro is not null
        or v_endereco.cidade is not null
      )
    ),
    'Atualizacao de endereco padrao pela pagina /dados-pessoais/.'
  );

  return query
  select *
  from public.shopping_endereco_padrao_atual();
end;
$$;

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'shopping-avatars',
  'shopping-avatars',
  false,
  5242880,
  array[
    'image/jpeg',
    'image/png',
    'image/webp'
  ]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists shopping_avatars_storage_select_self on storage.objects;
create policy shopping_avatars_storage_select_self
on storage.objects
for select
to authenticated
using (
  bucket_id = 'shopping-avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists shopping_avatars_storage_insert_self on storage.objects;
create policy shopping_avatars_storage_insert_self
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'shopping-avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists shopping_avatars_storage_update_self on storage.objects;
create policy shopping_avatars_storage_update_self
on storage.objects
for update
to authenticated
using (
  bucket_id = 'shopping-avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'shopping-avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists shopping_avatars_storage_delete_self on storage.objects;
create policy shopping_avatars_storage_delete_self
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'shopping-avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
);

revoke all on function public.shopping_perfil_atual() from public, anon, authenticated;
revoke all on function public.shopping_perfil_pessoal_salvar(text, text, text, text) from public, anon, authenticated;
revoke all on function public.shopping_endereco_padrao_atual() from public, anon, authenticated;
revoke all on function public.shopping_endereco_padrao_salvar(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;

grant execute on function public.shopping_perfil_atual() to authenticated;
grant execute on function public.shopping_perfil_pessoal_salvar(text, text, text, text) to authenticated;
grant execute on function public.shopping_endereco_padrao_atual() to authenticated;
grant execute on function public.shopping_endereco_padrao_salvar(text, text, text, text, text, text, text, text, text) to authenticated;

comment on column public.shopping_perfis.nome_completo is
  'Nome completo informado pelo usuario na pagina de dados pessoais.';

comment on column public.shopping_perfis.avatar_path is
  'Caminho privado do avatar no bucket shopping-avatars. Nao armazena URL assinada.';

comment on column public.shopping_perfis.pagamento_preferido is
  'Metodo preferido para iniciar o checkout: pix, cartao_debito ou cartao_credito. Nao guarda dados de cartao.';

comment on table public.shopping_enderecos is
  'Enderecos de entrega do usuario. WEB-02 usa um endereco padrao por usuario.';

comment on function public.shopping_perfil_pessoal_salvar(text, text, text, text) is
  'Autosservico do usuario autenticado para nome completo, telefone, avatar e preferencia de pagamento, sem alterar papel/status/escopos.';

comment on function public.shopping_endereco_padrao_atual() is
  'Retorna somente o endereco padrao do usuario autenticado.';

comment on function public.shopping_endereco_padrao_salvar(text, text, text, text, text, text, text, text, text) is
  'Cria ou atualiza o endereco padrao do usuario autenticado usando auth.uid().';

comment on policy shopping_avatars_storage_insert_self on storage.objects is
  'Permite upload de avatar somente na pasta inicial igual ao UID do usuario autenticado.';
