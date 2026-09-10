-- IAGO Shopping - WEB-11
-- Cadastro de parceiro com aceite versionado dos termos e aprovacao Master.

do $$
begin
  create type public.shopping_tipo_pessoa_parceiro as enum ('PF', 'PJ');
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type public.shopping_status_solicitacao_parceiro as enum ('pendente', 'aprovado', 'recusado');
exception
  when duplicate_object then null;
end
$$;

create table if not exists public.shopping_termos_aceites (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  termo_id text not null,
  versao_termo text not null,
  documento_hash text not null,
  documento_url text not null,
  tipo_pessoa public.shopping_tipo_pessoa_parceiro not null,
  aceito_em timestamptz not null default now(),
  ip_aceite inet,
  user_agent text,
  origem text not null default 'cadastro_parceiro',
  constraint shopping_termos_aceites_termo_id_not_blank check (btrim(termo_id) <> ''),
  constraint shopping_termos_aceites_versao_not_blank check (btrim(versao_termo) <> ''),
  constraint shopping_termos_aceites_hash_sha256 check (documento_hash ~ '^[A-Fa-f0-9]{64}$'),
  constraint shopping_termos_aceites_url_not_blank check (btrim(documento_url) <> ''),
  constraint shopping_termos_aceites_origem_not_blank check (btrim(origem) <> ''),
  constraint shopping_termos_aceites_unico unique (user_id, termo_id, versao_termo)
);

create index if not exists idx_shopping_termos_aceites_user_data
  on public.shopping_termos_aceites (user_id, aceito_em desc);

create table if not exists public.shopping_solicitacoes_parceiro (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  aceite_id uuid not null references public.shopping_termos_aceites(id) on delete restrict,
  tipo_pessoa public.shopping_tipo_pessoa_parceiro not null,
  documento_normalizado text not null,
  nome text not null,
  nome_loja text,
  telefone_normalizado text,
  status public.shopping_status_solicitacao_parceiro not null default 'pendente',
  solicitado_em timestamptz not null default now(),
  decidido_em timestamptz,
  decidido_por uuid references auth.users(id) on delete set null,
  motivo_decisao text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_solicitacoes_parceiro_documento_not_blank check (btrim(documento_normalizado) <> ''),
  constraint shopping_solicitacoes_parceiro_nome_not_blank check (btrim(nome) <> ''),
  constraint shopping_solicitacoes_parceiro_nome_loja_not_blank check (nome_loja is null or btrim(nome_loja) <> ''),
  constraint shopping_solicitacoes_parceiro_telefone_not_blank check (telefone_normalizado is null or btrim(telefone_normalizado) <> '')
);

create index if not exists idx_shopping_solicitacoes_parceiro_status_data
  on public.shopping_solicitacoes_parceiro (status, solicitado_em desc);

create index if not exists idx_shopping_solicitacoes_parceiro_user_data
  on public.shopping_solicitacoes_parceiro (user_id, solicitado_em desc);

create unique index if not exists idx_shopping_solicitacoes_parceiro_um_pendente
  on public.shopping_solicitacoes_parceiro (user_id)
  where status = 'pendente'::public.shopping_status_solicitacao_parceiro;

drop trigger if exists trg_shopping_solicitacoes_parceiro_touch on public.shopping_solicitacoes_parceiro;
create trigger trg_shopping_solicitacoes_parceiro_touch
before update on public.shopping_solicitacoes_parceiro
for each row execute function public.shopping_touch_atualizado_em();

alter table public.shopping_termos_aceites enable row level security;
alter table public.shopping_solicitacoes_parceiro enable row level security;

drop policy if exists shopping_termos_aceites_select_self_or_master on public.shopping_termos_aceites;
create policy shopping_termos_aceites_select_self_or_master
on public.shopping_termos_aceites
for select
to authenticated
using (
  user_id = auth.uid()
  or public.shopping_is_master(auth.uid())
);

drop policy if exists shopping_solicitacoes_parceiro_select_self_or_master on public.shopping_solicitacoes_parceiro;
create policy shopping_solicitacoes_parceiro_select_self_or_master
on public.shopping_solicitacoes_parceiro
for select
to authenticated
using (
  user_id = auth.uid()
  or public.shopping_is_master(auth.uid())
);

revoke all on public.shopping_termos_aceites from anon, authenticated;
revoke all on public.shopping_solicitacoes_parceiro from anon, authenticated;

grant select on public.shopping_termos_aceites to authenticated;
grant select on public.shopping_solicitacoes_parceiro to authenticated;

drop function if exists public.shopping_parceiro_solicitar_cadastro(
  text,
  text,
  text,
  text,
  text,
  boolean,
  text
);

create or replace function public.shopping_parceiro_solicitar_cadastro(
  p_tipo_pessoa text,
  p_documento_normalizado text,
  p_nome text,
  p_nome_loja text default null,
  p_telefone_normalizado text default null,
  p_aceite boolean default false,
  p_user_agent text default null
)
returns table (
  solicitacao_id uuid,
  aceite_id uuid,
  status public.shopping_status_solicitacao_parceiro,
  termo_id text,
  versao_termo text,
  documento_hash text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_tipo_pessoa public.shopping_tipo_pessoa_parceiro;
  v_documento text := regexp_replace(coalesce(p_documento_normalizado, ''), '\D', '', 'g');
  v_nome text := nullif(btrim(p_nome), '');
  v_nome_loja text := nullif(btrim(p_nome_loja), '');
  v_telefone text := nullif(regexp_replace(coalesce(p_telefone_normalizado, ''), '\D', '', 'g'), '');
  v_termo_id constant text := 'termos-vendedores';
  v_versao_termo constant text := '1.0';
  v_documento_hash constant text := '47AD1E9869F29747F49AD0399C28784EC25030B8BF196FA8B5B3900467672BB7';
  v_documento_url constant text := '/assets/docs/termos/Termos_Condicoes_Vendedores_IAGO_Shopping_V1.0.pdf';
  v_aceite public.shopping_termos_aceites;
  v_solicitacao public.shopping_solicitacoes_parceiro;
  v_existing_pendente uuid;
begin
  if v_actor is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  if not coalesce(p_aceite, false) then
    raise exception 'Aceite dos Termos e Condicoes para Vendedores e obrigatorio.';
  end if;

  if p_tipo_pessoa not in ('PF', 'PJ') then
    raise exception 'Tipo de pessoa invalido.';
  end if;

  v_tipo_pessoa := p_tipo_pessoa::public.shopping_tipo_pessoa_parceiro;

  if v_tipo_pessoa = 'PF'::public.shopping_tipo_pessoa_parceiro and char_length(v_documento) <> 11 then
    raise exception 'CPF deve conter 11 numeros.';
  end if;

  if v_tipo_pessoa = 'PJ'::public.shopping_tipo_pessoa_parceiro and char_length(v_documento) <> 14 then
    raise exception 'CNPJ deve conter 14 numeros.';
  end if;

  if v_nome is null then
    raise exception 'Nome ou razao social e obrigatorio.';
  end if;

  if exists (
    select 1
    from public.shopping_perfis sp
    where sp.user_id = v_actor
      and sp.papel = 'parceiro'::public.shopping_papel
      and sp.status_ativacao = 'ativo'::public.shopping_status_ativacao
  ) then
    raise exception 'Conta ja esta ativa como parceiro.';
  end if;

  insert into public.shopping_termos_aceites (
    user_id,
    termo_id,
    versao_termo,
    documento_hash,
    documento_url,
    tipo_pessoa,
    ip_aceite,
    user_agent,
    origem
  )
  values (
    v_actor,
    v_termo_id,
    v_versao_termo,
    v_documento_hash,
    v_documento_url,
    v_tipo_pessoa,
    null,
    nullif(btrim(p_user_agent), ''),
    'cadastro_parceiro'
  )
  on conflict on constraint shopping_termos_aceites_unico do update
  set tipo_pessoa = excluded.tipo_pessoa,
      documento_hash = excluded.documento_hash,
      documento_url = excluded.documento_url,
      user_agent = excluded.user_agent,
      origem = excluded.origem
  returning * into v_aceite;

  select ss.id
  into v_existing_pendente
  from public.shopping_solicitacoes_parceiro ss
  where ss.user_id = v_actor
    and ss.status = 'pendente'::public.shopping_status_solicitacao_parceiro
  order by ss.solicitado_em desc
  limit 1
  for update;

  if v_existing_pendente is null then
    insert into public.shopping_solicitacoes_parceiro (
      user_id,
      aceite_id,
      tipo_pessoa,
      documento_normalizado,
      nome,
      nome_loja,
      telefone_normalizado,
      status
    )
    values (
      v_actor,
      v_aceite.id,
      v_tipo_pessoa,
      v_documento,
      v_nome,
      v_nome_loja,
      v_telefone,
      'pendente'::public.shopping_status_solicitacao_parceiro
    )
    returning * into v_solicitacao;
  else
    update public.shopping_solicitacoes_parceiro ss
    set aceite_id = v_aceite.id,
        tipo_pessoa = v_tipo_pessoa,
        documento_normalizado = v_documento,
        nome = v_nome,
        nome_loja = v_nome_loja,
        telefone_normalizado = v_telefone,
        motivo_decisao = null,
        decidido_em = null,
        decidido_por = null
    where ss.id = v_existing_pendente
    returning ss.* into v_solicitacao;
  end if;

  update public.shopping_perfis sp
  set nome_exibicao = coalesce(v_nome_loja, v_nome, sp.nome_exibicao),
      nome_completo = coalesce(v_nome, sp.nome_completo),
      telefone_normalizado = coalesce(v_telefone, sp.telefone_normalizado),
      atualizado_por = v_actor
  where sp.user_id = v_actor;

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
    'parceiro.solicitacao_cadastro',
    'shopping_solicitacoes_parceiro',
    v_solicitacao.id,
    jsonb_build_object(
      'status', v_solicitacao.status,
      'tipo_pessoa', v_solicitacao.tipo_pessoa,
      'termo_id', v_termo_id,
      'versao_termo', v_versao_termo,
      'documento_hash', v_documento_hash
    ),
    'Solicitacao de parceiro criada ou atualizada pela pagina /cadastro-parceiro/.'
  );

  return query
  select
    v_solicitacao.id,
    v_aceite.id,
    v_solicitacao.status,
    v_termo_id,
    v_versao_termo,
    v_documento_hash;
end;
$$;

drop function if exists public.shopping_admin_listar_solicitacoes_parceiro();
create or replace function public.shopping_admin_listar_solicitacoes_parceiro()
returns table (
  id uuid,
  user_id uuid,
  nome text,
  nome_loja text,
  email_normalizado text,
  telefone_normalizado text,
  tipo_pessoa public.shopping_tipo_pessoa_parceiro,
  documento_normalizado text,
  status public.shopping_status_solicitacao_parceiro,
  termo_id text,
  versao_termo text,
  documento_hash text,
  documento_url text,
  aceito_em timestamptz,
  solicitado_em timestamptz,
  decidido_em timestamptz,
  motivo_decisao text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.shopping_is_master(auth.uid()) then
    raise exception 'Somente master ativo pode listar solicitacoes de parceiros.';
  end if;

  return query
  select
    ss.id,
    ss.user_id,
    ss.nome,
    ss.nome_loja,
    sp.email_normalizado,
    coalesce(ss.telefone_normalizado, sp.telefone_normalizado) as telefone_normalizado,
    ss.tipo_pessoa,
    ss.documento_normalizado,
    ss.status,
    sta.termo_id,
    sta.versao_termo,
    sta.documento_hash,
    sta.documento_url,
    sta.aceito_em,
    ss.solicitado_em,
    ss.decidido_em,
    ss.motivo_decisao
  from public.shopping_solicitacoes_parceiro ss
  join public.shopping_termos_aceites sta on sta.id = ss.aceite_id
  left join public.shopping_perfis sp on sp.user_id = ss.user_id
  order by
    case ss.status
      when 'pendente'::public.shopping_status_solicitacao_parceiro then 0
      when 'recusado'::public.shopping_status_solicitacao_parceiro then 1
      else 2
    end,
    ss.solicitado_em desc;
end;
$$;

drop function if exists public.shopping_admin_decidir_solicitacao_parceiro(uuid, text, text);
create or replace function public.shopping_admin_decidir_solicitacao_parceiro(
  p_solicitacao_id uuid,
  p_decisao text,
  p_motivo text default null
)
returns table (
  solicitacao_id uuid,
  user_id uuid,
  status public.shopping_status_solicitacao_parceiro,
  perfil_papel public.shopping_papel,
  perfil_status public.shopping_status_ativacao
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_decisao public.shopping_status_solicitacao_parceiro;
  v_motivo text := nullif(btrim(p_motivo), '');
  v_antes_solicitacao jsonb;
  v_antes_perfil jsonb;
  v_solicitacao public.shopping_solicitacoes_parceiro;
  v_perfil public.shopping_perfis;
begin
  if v_actor is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  if not public.shopping_is_master(v_actor) then
    raise exception 'Somente master ativo pode aprovar ou recusar parceiros.';
  end if;

  if p_decisao is null or p_decisao not in ('aprovado', 'recusado') then
    raise exception 'Decisao invalida.';
  end if;

  v_decisao := p_decisao::public.shopping_status_solicitacao_parceiro;

  if v_decisao = 'recusado'::public.shopping_status_solicitacao_parceiro and v_motivo is null then
    raise exception 'Motivo da recusa e obrigatorio.';
  end if;

  select ss.*
  into v_solicitacao
  from public.shopping_solicitacoes_parceiro ss
  where ss.id = p_solicitacao_id
  for update;

  if v_solicitacao.id is null then
    raise exception 'Solicitacao de parceiro nao encontrada.';
  end if;

  v_antes_solicitacao := to_jsonb(v_solicitacao);

  if v_solicitacao.status <> 'pendente'::public.shopping_status_solicitacao_parceiro then
    raise exception 'Solicitacao ja foi decidida.';
  end if;

  select sp.*
  into v_perfil
  from public.shopping_perfis sp
  where sp.user_id = v_solicitacao.user_id
  for update;

  if v_perfil.id is null then
    raise exception 'Perfil da solicitacao nao encontrado.';
  end if;

  v_antes_perfil := to_jsonb(v_perfil);

  update public.shopping_solicitacoes_parceiro ss
  set status = v_decisao,
      decidido_em = now(),
      decidido_por = v_actor,
      motivo_decisao = v_motivo
  where ss.id = v_solicitacao.id
  returning ss.* into v_solicitacao;

  if v_decisao = 'aprovado'::public.shopping_status_solicitacao_parceiro then
    update public.shopping_perfis sp
    set papel = 'parceiro'::public.shopping_papel,
        status_ativacao = 'ativo'::public.shopping_status_ativacao,
        atualizado_por = v_actor
    where sp.user_id = v_solicitacao.user_id
    returning sp.* into v_perfil;
  end if;

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
    case
      when v_decisao = 'aprovado'::public.shopping_status_solicitacao_parceiro
        then 'parceiro.solicitacao_aprovada'
      else 'parceiro.solicitacao_recusada'
    end,
    'shopping_solicitacoes_parceiro',
    v_solicitacao.id,
    v_antes_solicitacao,
    to_jsonb(v_solicitacao),
    coalesce(v_motivo, 'Decisao Master do cadastro de parceiro.')
  );

  if v_decisao = 'aprovado'::public.shopping_status_solicitacao_parceiro then
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
      'perfil.parceiro_ativado_por_solicitacao',
      'shopping_perfis',
      v_perfil.id,
      v_antes_perfil,
      to_jsonb(v_perfil),
      coalesce(v_motivo, 'Aprovacao Master do cadastro de parceiro.')
    );
  end if;

  return query
  select
    v_solicitacao.id,
    v_solicitacao.user_id,
    v_solicitacao.status,
    v_perfil.papel,
    v_perfil.status_ativacao;
end;
$$;

revoke all on function public.shopping_parceiro_solicitar_cadastro(text, text, text, text, text, boolean, text) from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_solicitacoes_parceiro() from public, anon, authenticated;
revoke all on function public.shopping_admin_decidir_solicitacao_parceiro(uuid, text, text) from public, anon, authenticated;

grant execute on function public.shopping_parceiro_solicitar_cadastro(text, text, text, text, text, boolean, text) to authenticated;
grant execute on function public.shopping_admin_listar_solicitacoes_parceiro() to authenticated;
grant execute on function public.shopping_admin_decidir_solicitacao_parceiro(uuid, text, text) to authenticated;

comment on table public.shopping_termos_aceites is
  'Aceites versionados dos Termos e Condicoes para Vendedores do IAGO Shopping.';

comment on table public.shopping_solicitacoes_parceiro is
  'Solicitacoes publicas de evolucao para parceiro, aprovadas ou recusadas por Master.';

comment on function public.shopping_parceiro_solicitar_cadastro(text, text, text, text, text, boolean, text) is
  'Registra aceite versionado e cria/atualiza solicitacao pendente de parceiro usando auth.uid(), sem conceder papel parceiro.';

comment on function public.shopping_admin_listar_solicitacoes_parceiro() is
  'Lista solicitacoes de parceiro somente para Master ativo.';

comment on function public.shopping_admin_decidir_solicitacao_parceiro(uuid, text, text) is
  'Aprova ou recusa solicitacao de parceiro; aprovacao ativa papel parceiro via validacao Master.';

notify pgrst, 'reload schema';
