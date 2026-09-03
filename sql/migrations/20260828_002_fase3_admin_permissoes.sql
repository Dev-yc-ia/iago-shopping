-- IAGO Shopping - Fase 3
-- Administracao e permissoes.
--
-- Escopo:
-- - verificacao centralizada de acesso administrativo;
-- - leitura segura do perfil atual;
-- - listagem administrativa de perfis;
-- - ativacao/bloqueio/inativacao auditada de perfis;
-- - ajustes de FKs auxiliares para nao bloquear exclusao de usuarios.

create or replace function public.shopping_is_admin(p_user_id uuid default auth.uid())
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
      and sp.papel in (
        'master'::public.shopping_papel,
        'funcionario'::public.shopping_papel,
        'parceiro'::public.shopping_papel
      )
      and sp.status_ativacao = 'ativo'::public.shopping_status_ativacao
  );
$$;

create or replace function public.shopping_perfil_atual()
returns table (
  user_id uuid,
  nome_exibicao text,
  email_normalizado text,
  telefone_normalizado text,
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
    sp.email_normalizado,
    sp.telefone_normalizado,
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

create or replace function public.shopping_admin_listar_perfis()
returns table (
  user_id uuid,
  nome_exibicao text,
  email_normalizado text,
  telefone_normalizado text,
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

  if not public.shopping_is_master(auth.uid()) then
    raise exception 'Somente master ativo pode listar perfis administrativos.';
  end if;

  return query
  select
    sp.user_id,
    sp.nome_exibicao,
    sp.email_normalizado,
    sp.telefone_normalizado,
    sp.papel,
    sp.escopos,
    sp.status_convite,
    sp.status_ativacao,
    sp.origem,
    sp.criado_em,
    sp.atualizado_em
  from public.shopping_perfis sp
  order by sp.criado_em desc, sp.email_normalizado nulls last;
end;
$$;

create or replace function public.shopping_admin_definir_status_ativacao(
  p_user_id uuid,
  p_status_ativacao public.shopping_status_ativacao,
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
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  if not public.shopping_is_master(v_actor) then
    raise exception 'Somente master ativo pode alterar status de ativacao.';
  end if;

  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Motivo e obrigatorio para auditoria.';
  end if;

  if p_user_id = v_actor and p_status_ativacao <> 'ativo'::public.shopping_status_ativacao then
    raise exception 'Master nao pode desativar o proprio perfil por esta funcao.';
  end if;

  select to_jsonb(sp.*)
  into v_antes
  from public.shopping_perfis sp
  where sp.user_id = p_user_id
  for update;

  if v_antes is null then
    raise exception 'Perfil alvo nao encontrado.';
  end if;

  update public.shopping_perfis
  set status_ativacao = p_status_ativacao,
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
    'perfil.definir_status_ativacao',
    'shopping_perfis',
    v_perfil.id,
    v_antes,
    to_jsonb(v_perfil),
    p_motivo
  );

  return v_perfil;
end;
$$;

alter table public.shopping_perfis
  drop constraint if exists shopping_perfis_criado_por_fkey,
  add constraint shopping_perfis_criado_por_fkey
    foreign key (criado_por) references auth.users(id) on delete set null;

alter table public.shopping_perfis
  drop constraint if exists shopping_perfis_atualizado_por_fkey,
  add constraint shopping_perfis_atualizado_por_fkey
    foreign key (atualizado_por) references auth.users(id) on delete set null;

alter table public.shopping_convites
  drop constraint if exists shopping_convites_criado_por_fkey,
  add constraint shopping_convites_criado_por_fkey
    foreign key (criado_por) references auth.users(id) on delete set null;

alter table public.shopping_convites
  drop constraint if exists shopping_convites_aceito_por_fkey,
  add constraint shopping_convites_aceito_por_fkey
    foreign key (aceito_por) references auth.users(id) on delete set null;

alter table public.shopping_auditoria
  drop constraint if exists shopping_auditoria_ator_user_id_fkey,
  add constraint shopping_auditoria_ator_user_id_fkey
    foreign key (ator_user_id) references auth.users(id) on delete set null;

revoke all on function public.shopping_is_admin(uuid) from public, anon, authenticated;
revoke all on function public.shopping_perfil_atual() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_perfis() from public, anon, authenticated;
revoke all on function public.shopping_admin_definir_status_ativacao(
  uuid,
  public.shopping_status_ativacao,
  text
) from public, anon, authenticated;

grant execute on function public.shopping_is_admin(uuid) to authenticated;
grant execute on function public.shopping_perfil_atual() to authenticated;
grant execute on function public.shopping_admin_listar_perfis() to authenticated;
grant execute on function public.shopping_admin_definir_status_ativacao(
  uuid,
  public.shopping_status_ativacao,
  text
) to authenticated;

comment on function public.shopping_is_admin(uuid) is
  'Verifica acesso administrativo ativo para master, funcionario ou parceiro.';

comment on function public.shopping_perfil_atual() is
  'Retorna o perfil do usuario autenticado para sessao, menu dinamico e autorizacao no frontend.';

comment on function public.shopping_admin_listar_perfis() is
  'Lista perfis para administracao por master ativo.';

comment on function public.shopping_admin_definir_status_ativacao(
  uuid,
  public.shopping_status_ativacao,
  text
) is
  'Funcao administrativa auditada para master ativo ativar, bloquear ou inativar perfis.';
