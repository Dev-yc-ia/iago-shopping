-- IAGO Shopping - Fase 1 preparada
-- Migração revisável para executar manualmente no SQL Editor do Supabase.
--
-- Escopo:
-- - aplicação/banco lógico do Shopping separado da Pesquisa;
-- - vínculo com Pesquisa somente por response_id;
-- - nenhuma resposta individual da Pesquisa é copiada;
-- - senhas permanecem exclusivamente no Supabase Auth;
-- - tokens de convite nunca são armazenados em texto aberto.

create extension if not exists pgcrypto;

do $$
begin
  create type public.shopping_origem_perfil as enum ('pesquisa', 'cadastro_direto');
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type public.shopping_papel as enum ('cliente', 'funcionario', 'parceiro', 'master');
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type public.shopping_status_convite as enum ('sem_convite', 'pendente', 'enviado', 'aceito', 'expirado', 'cancelado');
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type public.shopping_status_ativacao as enum ('pendente', 'ativo', 'bloqueado', 'inativo');
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type public.shopping_tipo_contato as enum ('email', 'telefone');
exception
  when duplicate_object then null;
end
$$;

create table if not exists public.shopping_perfis (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  response_id text unique,
  origem public.shopping_origem_perfil not null default 'cadastro_direto',
  nome_exibicao text,
  email_normalizado text,
  telefone_normalizado text,
  papel public.shopping_papel not null default 'cliente',
  escopos jsonb not null default '{}'::jsonb,
  status_convite public.shopping_status_convite not null default 'sem_convite',
  status_ativacao public.shopping_status_ativacao not null default 'pendente',
  criado_por uuid references auth.users(id),
  atualizado_por uuid references auth.users(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_perfis_response_id_not_blank check (response_id is null or btrim(response_id) <> ''),
  constraint shopping_perfis_nome_not_blank check (nome_exibicao is null or btrim(nome_exibicao) <> ''),
  constraint shopping_perfis_email_normalizado check (
    email_normalizado is null or email_normalizado = lower(btrim(email_normalizado))
  ),
  constraint shopping_perfis_telefone_not_blank check (
    telefone_normalizado is null or btrim(telefone_normalizado) <> ''
  ),
  constraint shopping_perfis_escopos_object check (jsonb_typeof(escopos) = 'object')
);

create index if not exists idx_shopping_perfis_user_id
  on public.shopping_perfis (user_id);

create index if not exists idx_shopping_perfis_response_id
  on public.shopping_perfis (response_id)
  where response_id is not null;

create index if not exists idx_shopping_perfis_papel_status
  on public.shopping_perfis (papel, status_ativacao);

create table if not exists public.shopping_convites (
  id uuid primary key default gen_random_uuid(),
  response_id text unique,
  contato_tipo public.shopping_tipo_contato not null,
  contato_normalizado text,
  contato_hash text not null,
  convite_hash text not null unique,
  papel_destino public.shopping_papel not null default 'cliente',
  status public.shopping_status_convite not null default 'pendente',
  criado_por uuid references auth.users(id),
  aceito_por uuid references auth.users(id),
  expira_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_convites_response_id_not_blank check (response_id is null or btrim(response_id) <> ''),
  constraint shopping_convites_contato_not_blank check (btrim(contato_hash) <> ''),
  constraint shopping_convites_hash_not_blank check (btrim(convite_hash) <> ''),
  constraint shopping_convites_sem_master_por_convite check (papel_destino <> 'master')
);

create index if not exists idx_shopping_convites_response_id
  on public.shopping_convites (response_id)
  where response_id is not null;

create index if not exists idx_shopping_convites_contato_hash
  on public.shopping_convites (contato_hash);

create index if not exists idx_shopping_convites_status
  on public.shopping_convites (status);

create table if not exists public.shopping_auditoria (
  id bigint generated always as identity primary key,
  ator_user_id uuid references auth.users(id),
  acao text not null,
  tabela text not null,
  registro_id uuid,
  antes jsonb,
  depois jsonb,
  motivo text,
  criado_em timestamptz not null default now(),
  constraint shopping_auditoria_acao_not_blank check (btrim(acao) <> ''),
  constraint shopping_auditoria_tabela_not_blank check (btrim(tabela) <> '')
);

create index if not exists idx_shopping_auditoria_ator_data
  on public.shopping_auditoria (ator_user_id, criado_em desc);

create index if not exists idx_shopping_auditoria_tabela_registro
  on public.shopping_auditoria (tabela, registro_id);

create or replace function public.shopping_touch_atualizado_em()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.atualizado_em = now();
  return new;
end;
$$;

drop trigger if exists trg_shopping_perfis_touch on public.shopping_perfis;
create trigger trg_shopping_perfis_touch
before update on public.shopping_perfis
for each row execute function public.shopping_touch_atualizado_em();

drop trigger if exists trg_shopping_convites_touch on public.shopping_convites;
create trigger trg_shopping_convites_touch
before update on public.shopping_convites
for each row execute function public.shopping_touch_atualizado_em();

create or replace function public.shopping_is_master(p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.shopping_perfis sp
    where sp.user_id = p_user_id
      and sp.papel = 'master'::public.shopping_papel
      and sp.status_ativacao = 'ativo'::public.shopping_status_ativacao
  );
$$;

create or replace function public.shopping_guard_perfis_menor_privilegio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_is_master boolean := public.shopping_is_master(v_actor);
begin
  if v_actor is null then
    return new;
  end if;

  if coalesce(v_is_master, false) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.user_id <> v_actor then
      raise exception 'Perfil só pode ser criado para o próprio usuário autenticado.';
    end if;

    new.criado_por := v_actor;
    new.atualizado_por := v_actor;

    if new.response_id is not null then
      raise exception 'Criação comum não pode vincular response_id.';
    end if;

    if new.origem <> 'cadastro_direto'::public.shopping_origem_perfil then
      raise exception 'Criação comum deve usar origem cadastro_direto.';
    end if;

    if new.papel <> 'cliente'::public.shopping_papel then
      raise exception 'Criação comum não pode definir papel privilegiado.';
    end if;

    if new.escopos <> '{}'::jsonb then
      raise exception 'Criação comum não pode definir escopos.';
    end if;

    if new.status_convite <> 'sem_convite'::public.shopping_status_convite
      or new.status_ativacao <> 'pendente'::public.shopping_status_ativacao then
      raise exception 'Criação comum não pode definir status administrativo.';
    end if;

    return new;
  end if;

  if new.user_id <> old.user_id then
    raise exception 'Usuário comum não pode alterar user_id.';
  end if;

  if new.criado_por is distinct from old.criado_por then
    raise exception 'Usuário comum não pode alterar autoria de criação.';
  end if;

  if new.response_id is distinct from old.response_id then
    raise exception 'Usuário comum não pode alterar vínculo com pesquisa.';
  end if;

  if new.origem is distinct from old.origem then
    raise exception 'Usuário comum não pode alterar origem do perfil.';
  end if;

  if new.papel is distinct from old.papel then
    raise exception 'Usuário comum não pode alterar papel.';
  end if;

  if new.escopos is distinct from old.escopos then
    raise exception 'Usuário comum não pode alterar escopos.';
  end if;

  if new.status_convite is distinct from old.status_convite
    or new.status_ativacao is distinct from old.status_ativacao then
    raise exception 'Usuário comum não pode alterar status administrativo.';
  end if;

  new.atualizado_por := v_actor;
  return new;
end;
$$;

drop trigger if exists trg_shopping_perfis_menor_privilegio on public.shopping_perfis;
create trigger trg_shopping_perfis_menor_privilegio
before insert or update on public.shopping_perfis
for each row execute function public.shopping_guard_perfis_menor_privilegio();

create or replace function public.shopping_bootstrap_primeiro_master(
  p_user_id uuid,
  p_email_normalizado text default null,
  p_nome_exibicao text default 'Master IAGO Shopping'
)
returns public.shopping_perfis
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis;
begin
  if exists (
    select 1
    from public.shopping_perfis
    where papel = 'master'::public.shopping_papel
      and status_ativacao = 'ativo'::public.shopping_status_ativacao
  ) then
    raise exception 'Bootstrap bloqueado: já existe master ativo.';
  end if;

  insert into public.shopping_perfis (
    user_id,
    origem,
    nome_exibicao,
    email_normalizado,
    papel,
    status_convite,
    status_ativacao,
    criado_por,
    atualizado_por
  )
  values (
    p_user_id,
    'cadastro_direto'::public.shopping_origem_perfil,
    p_nome_exibicao,
    case when p_email_normalizado is null then null else lower(btrim(p_email_normalizado)) end,
    'master'::public.shopping_papel,
    'sem_convite'::public.shopping_status_convite,
    'ativo'::public.shopping_status_ativacao,
    p_user_id,
    p_user_id
  )
  on conflict (user_id) do update
  set papel = 'master'::public.shopping_papel,
      status_ativacao = 'ativo'::public.shopping_status_ativacao,
      status_convite = 'sem_convite'::public.shopping_status_convite,
      email_normalizado = coalesce(excluded.email_normalizado, public.shopping_perfis.email_normalizado),
      nome_exibicao = coalesce(excluded.nome_exibicao, public.shopping_perfis.nome_exibicao),
      atualizado_por = p_user_id,
      atualizado_em = now()
  returning * into v_perfil;

  insert into public.shopping_auditoria (
    ator_user_id,
    acao,
    tabela,
    registro_id,
    depois,
    motivo
  )
  values (
    p_user_id,
    'bootstrap.primeiro_master',
    'shopping_perfis',
    v_perfil.id,
    to_jsonb(v_perfil),
    'Bootstrap controlado pelo SQL Editor após criação/login no Supabase Auth.'
  );

  return v_perfil;
end;
$$;

create or replace function public.shopping_admin_definir_papel(
  p_user_id uuid,
  p_papel public.shopping_papel,
  p_motivo text
)
returns public.shopping_perfis
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_antes jsonb;
  v_perfil public.shopping_perfis;
begin
  if v_actor is null then
    raise exception 'Operação exige usuário autenticado.';
  end if;

  if not public.shopping_is_master(v_actor) then
    raise exception 'Somente master ativo pode alterar papéis.';
  end if;

  if p_user_id = v_actor then
    raise exception 'Alteração do próprio papel não é permitida por esta função.';
  end if;

  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Motivo é obrigatório para auditoria.';
  end if;

  select to_jsonb(sp.*)
  into v_antes
  from public.shopping_perfis sp
  where sp.user_id = p_user_id
  for update;

  if v_antes is null then
    raise exception 'Perfil alvo não encontrado.';
  end if;

  update public.shopping_perfis
  set papel = p_papel,
      atualizado_por = v_actor
  where user_id = p_user_id
  returning * into v_perfil;

  insert into public.shopping_auditoria (
    ator_user_id,
    acao,
    tabela,
    registro_id,
    antes,
    depois,
    motivo
  )
  values (
    v_actor,
    'perfil.definir_papel',
    'shopping_perfis',
    v_perfil.id,
    v_antes,
    to_jsonb(v_perfil),
    p_motivo
  );

  return v_perfil;
end;
$$;

create or replace function public.shopping_admin_definir_escopos(
  p_user_id uuid,
  p_escopos jsonb,
  p_motivo text
)
returns public.shopping_perfis
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_antes jsonb;
  v_perfil public.shopping_perfis;
begin
  if v_actor is null then
    raise exception 'Operação exige usuário autenticado.';
  end if;

  if not public.shopping_is_master(v_actor) then
    raise exception 'Somente master ativo pode alterar escopos.';
  end if;

  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Motivo é obrigatório para auditoria.';
  end if;

  if p_escopos is null or jsonb_typeof(p_escopos) <> 'object' then
    raise exception 'Escopos devem ser um objeto JSON.';
  end if;

  select to_jsonb(sp.*)
  into v_antes
  from public.shopping_perfis sp
  where sp.user_id = p_user_id
  for update;

  if v_antes is null then
    raise exception 'Perfil alvo não encontrado.';
  end if;

  update public.shopping_perfis
  set escopos = p_escopos,
      atualizado_por = v_actor
  where user_id = p_user_id
  returning * into v_perfil;

  insert into public.shopping_auditoria (
    ator_user_id,
    acao,
    tabela,
    registro_id,
    antes,
    depois,
    motivo
  )
  values (
    v_actor,
    'perfil.definir_escopos',
    'shopping_perfis',
    v_perfil.id,
    v_antes,
    to_jsonb(v_perfil),
    p_motivo
  );

  return v_perfil;
end;
$$;

alter table public.shopping_perfis enable row level security;
alter table public.shopping_convites enable row level security;
alter table public.shopping_auditoria enable row level security;

drop policy if exists shopping_perfis_select_self_or_master on public.shopping_perfis;
create policy shopping_perfis_select_self_or_master
on public.shopping_perfis
for select
to authenticated
using (
  user_id = auth.uid()
  or public.shopping_is_master(auth.uid())
);

drop policy if exists shopping_perfis_insert_self_cliente on public.shopping_perfis;
create policy shopping_perfis_insert_self_cliente
on public.shopping_perfis
for insert
to authenticated
with check (
  user_id = auth.uid()
  and papel = 'cliente'::public.shopping_papel
  and escopos = '{}'::jsonb
);

drop policy if exists shopping_perfis_update_self_limited_or_master on public.shopping_perfis;
create policy shopping_perfis_update_self_limited_or_master
on public.shopping_perfis
for update
to authenticated
using (
  user_id = auth.uid()
  or public.shopping_is_master(auth.uid())
)
with check (
  user_id = auth.uid()
  or public.shopping_is_master(auth.uid())
);

drop policy if exists shopping_convites_master_all on public.shopping_convites;
create policy shopping_convites_master_all
on public.shopping_convites
for all
to authenticated
using (public.shopping_is_master(auth.uid()))
with check (public.shopping_is_master(auth.uid()));

drop policy if exists shopping_auditoria_master_select on public.shopping_auditoria;
create policy shopping_auditoria_master_select
on public.shopping_auditoria
for select
to authenticated
using (public.shopping_is_master(auth.uid()));

revoke all on public.shopping_perfis from anon, authenticated;
revoke all on public.shopping_convites from anon, authenticated;
revoke all on public.shopping_auditoria from anon, authenticated;

grant select, insert on public.shopping_perfis to authenticated;
grant update (
  nome_exibicao,
  email_normalizado,
  telefone_normalizado
) on public.shopping_perfis to authenticated;

grant select, insert, update on public.shopping_convites to authenticated;
grant select on public.shopping_auditoria to authenticated;

revoke all on function public.shopping_bootstrap_primeiro_master(uuid, text, text) from public, anon, authenticated;
grant execute on function public.shopping_is_master(uuid) to authenticated;
grant execute on function public.shopping_admin_definir_papel(uuid, public.shopping_papel, text) to authenticated;
grant execute on function public.shopping_admin_definir_escopos(uuid, jsonb, text) to authenticated;

comment on table public.shopping_perfis is
  'Perfis do IAGO Shopping. Referencia Pesquisa apenas por response_id; não copia respostas individuais.';

comment on column public.shopping_perfis.response_id is
  'Identificador lógico opcional da resposta na Pesquisa. Sem FK e sem cópia de respostas individuais.';

comment on column public.shopping_perfis.email_normalizado is
  'Contato normalizado para operação. Senhas ficam somente no Supabase Auth.';

comment on table public.shopping_convites is
  'Convites idempotentes do Shopping. Armazena hashes, nunca tokens em texto aberto.';

comment on function public.shopping_bootstrap_primeiro_master(uuid, text, text) is
  'Função para SQL Editor/admin criar o primeiro master após o usuário existir no Supabase Auth. Não concedida a authenticated.';

comment on function public.shopping_admin_definir_papel(uuid, public.shopping_papel, text) is
  'Função administrativa auditada para master ativo alterar papel de outro usuário, sem autoelevação.';
