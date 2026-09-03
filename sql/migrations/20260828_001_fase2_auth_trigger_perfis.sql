-- IAGO Shopping - Fase 2
-- Criacao automatica de perfil a partir do Supabase Auth.
--
-- Escopo:
-- - todo novo usuario criado em auth.users nasce com shopping_perfis;
-- - o frontend deixa de ser responsavel por inserir perfil;
-- - senhas permanecem exclusivamente no Supabase Auth;
-- - dados iniciais seguem menor privilegio: cliente pendente.

create or replace function public.shopping_handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_email_normalizado text := nullif(lower(btrim(new.email)), '');
  v_nome_exibicao text := nullif(btrim(coalesce(
    new.raw_user_meta_data ->> 'nome_exibicao',
    new.raw_user_meta_data ->> 'name',
    split_part(new.email, '@', 1),
    'Cliente IAGO'
  )), '');
begin
  insert into public.shopping_perfis (
    user_id,
    origem,
    nome_exibicao,
    email_normalizado,
    papel,
    status_ativacao,
    status_convite,
    criado_por,
    atualizado_por,
    criado_em,
    atualizado_em
  )
  values (
    new.id,
    'cadastro_direto'::public.shopping_origem_perfil,
    coalesce(v_nome_exibicao, 'Cliente IAGO'),
    v_email_normalizado,
    'cliente'::public.shopping_papel,
    'pendente'::public.shopping_status_ativacao,
    'sem_convite'::public.shopping_status_convite,
    new.id,
    new.id,
    now(),
    now()
  )
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists trg_shopping_auth_user_created on auth.users;
create trigger trg_shopping_auth_user_created
after insert on auth.users
for each row
execute function public.shopping_handle_new_auth_user();

insert into public.shopping_perfis (
  user_id,
  origem,
  nome_exibicao,
  email_normalizado,
  papel,
  status_ativacao,
  status_convite,
  criado_por,
  atualizado_por,
  criado_em,
  atualizado_em
)
select
  au.id,
  'cadastro_direto'::public.shopping_origem_perfil,
  coalesce(
    nullif(btrim(au.raw_user_meta_data ->> 'nome_exibicao'), ''),
    nullif(btrim(au.raw_user_meta_data ->> 'name'), ''),
    nullif(btrim(split_part(au.email, '@', 1)), ''),
    'Cliente IAGO'
  ),
  nullif(lower(btrim(au.email)), ''),
  'cliente'::public.shopping_papel,
  'pendente'::public.shopping_status_ativacao,
  'sem_convite'::public.shopping_status_convite,
  au.id,
  au.id,
  now(),
  now()
from auth.users au
where not exists (
  select 1
  from public.shopping_perfis sp
  where sp.user_id = au.id
);

comment on function public.shopping_handle_new_auth_user() is
  'Cria automaticamente shopping_perfis para novos usuarios do Supabase Auth, sem depender do frontend ou de sessao ativa.';
