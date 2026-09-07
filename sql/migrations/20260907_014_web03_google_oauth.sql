-- IAGO Shopping - WEB-03
-- Login com Google, sincronizacao minima de perfil e avatar Google como fallback visual.
--
-- Escopo:
-- - nao cria tabelas novas;
-- - nao persiste URL de avatar Google;
-- - nao altera papel, status, escopos, carrinhos, pedidos ou pagamentos;
-- - sincroniza apenas nome/e-mail operacional do usuario autenticado.

create or replace function public.shopping_perfil_oauth_sincronizar(
  p_nome_google text default null,
  p_email_normalizado text default null
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
  v_nome_google text := nullif(btrim(p_nome_google), '');
  v_email_param text := nullif(lower(btrim(p_email_normalizado)), '');
  v_email_auth text;
  v_perfil public.shopping_perfis;
  v_changed_rows integer := 0;
begin
  if v_actor is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  select nullif(lower(btrim(au.email)), '')
  into v_email_auth
  from auth.users au
  where au.id = v_actor;

  if v_email_auth is null then
    v_email_auth := v_email_param;
  end if;

  select *
  into v_perfil
  from public.shopping_perfis sp
  where sp.user_id = v_actor
  for update;

  if v_perfil.id is null then
    raise exception 'Perfil do usuario autenticado nao encontrado.';
  end if;

  update public.shopping_perfis sp
  set nome_completo = case
        when sp.nome_completo is null and v_nome_google is not null then v_nome_google
        else sp.nome_completo
      end,
      nome_exibicao = case
        when sp.nome_exibicao is null and v_nome_google is not null then v_nome_google
        when sp.nome_exibicao is null and v_email_auth is not null then split_part(v_email_auth, '@', 1)
        else sp.nome_exibicao
      end,
      email_normalizado = coalesce(v_email_auth, sp.email_normalizado),
      atualizado_por = v_actor
  where sp.user_id = v_actor
    and (
      (sp.nome_completo is null and v_nome_google is not null)
      or (sp.nome_exibicao is null and (v_nome_google is not null or v_email_auth is not null))
      or (v_email_auth is not null and sp.email_normalizado is distinct from v_email_auth)
    )
  returning * into v_perfil;

  get diagnostics v_changed_rows = row_count;

  if v_changed_rows > 0 then
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
      'perfil.oauth_google_sincronizado',
      'shopping_perfis',
      v_perfil.id,
      jsonb_build_object(
        'nome_completo_preenchido', v_perfil.nome_completo is not null,
        'nome_exibicao_preenchido', v_perfil.nome_exibicao is not null,
        'email_normalizado_sincronizado', v_perfil.email_normalizado is not null
      ),
      'Sincronizacao minima apos login Google OAuth.'
    );
  end if;

  return query
  select *
  from public.shopping_perfil_atual();
end;
$$;

revoke all on function public.shopping_perfil_oauth_sincronizar(text, text) from public, anon, authenticated;
grant execute on function public.shopping_perfil_oauth_sincronizar(text, text) to authenticated;

comment on function public.shopping_perfil_oauth_sincronizar(text, text) is
  'Sincroniza dados minimos apos Google OAuth usando auth.uid(), sem alterar papel/status/escopos e sem persistir URL de avatar Google.';
