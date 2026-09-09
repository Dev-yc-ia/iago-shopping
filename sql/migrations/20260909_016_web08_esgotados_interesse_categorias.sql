-- IAGO Shopping - WEB-08
-- Produtos esgotados, interesse de compra e categorias dinamicas no frontend.
--
-- Escopo:
-- - persistencia de interesse em produto esgotado;
-- - RPC segura usando auth.uid();
-- - RLS para cliente consultar/criar somente o proprio interesse;
-- - leitura administrativa agregavel por papeis existentes.

create table if not exists public.shopping_produto_interesses (
  id uuid primary key default gen_random_uuid(),
  produto_id uuid not null references public.shopping_produtos(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_produto_interesses_produto_user_unique unique (produto_id, user_id)
);

create index if not exists idx_shopping_produto_interesses_produto_data
  on public.shopping_produto_interesses (produto_id, criado_em desc);

create index if not exists idx_shopping_produto_interesses_user_data
  on public.shopping_produto_interesses (user_id, criado_em desc);

drop trigger if exists trg_shopping_produto_interesses_touch on public.shopping_produto_interesses;
create trigger trg_shopping_produto_interesses_touch
before update on public.shopping_produto_interesses
for each row execute function public.shopping_touch_atualizado_em();

alter table public.shopping_produto_interesses enable row level security;

drop policy if exists shopping_produto_interesses_select_self_or_admin on public.shopping_produto_interesses;
create policy shopping_produto_interesses_select_self_or_admin
on public.shopping_produto_interesses
for select
to authenticated
using (
  user_id = auth.uid()
  or public.shopping_is_admin(auth.uid())
);

drop policy if exists shopping_produto_interesses_insert_self on public.shopping_produto_interesses;
create policy shopping_produto_interesses_insert_self
on public.shopping_produto_interesses
for insert
to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1
    from public.shopping_produtos sp
    where sp.id = produto_id
      and sp.status = 'publicado'::public.shopping_status_produto
      and not exists (
        select 1
        from public.shopping_produto_variacoes spv
        where spv.produto_id = sp.id
          and spv.ativo
          and spv.estoque_atual > 0
      )
  )
);

revoke all on public.shopping_produto_interesses from anon, authenticated;
grant select, insert on public.shopping_produto_interesses to authenticated;

drop function if exists public.shopping_produto_interesse_status(uuid);
create or replace function public.shopping_produto_interesse_status(
  p_produto_id uuid
)
returns table (
  registrado boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.shopping_produto_interesses spi
    where spi.produto_id = p_produto_id
      and spi.user_id = auth.uid()
  ) as registrado
  where auth.uid() is not null;
$$;

drop function if exists public.shopping_produto_interesse_registrar(uuid);
create or replace function public.shopping_produto_interesse_registrar(
  p_produto_id uuid
)
returns table (
  registrado boolean,
  criado boolean,
  mensagem text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_produto public.shopping_produtos;
  v_estoque_total integer := 0;
  v_interesse_id uuid;
begin
  if v_user_id is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  if p_produto_id is null then
    raise exception 'Produto obrigatorio para registrar interesse.';
  end if;

  select *
  into v_produto
  from public.shopping_produtos sp
  where sp.id = p_produto_id
    and sp.status = 'publicado'::public.shopping_status_produto;

  if v_produto.id is null then
    raise exception 'Produto indisponivel para registrar interesse.';
  end if;

  perform 1
  from public.shopping_produto_variacoes spv
  where spv.produto_id = p_produto_id
    and spv.ativo
  for update;

  select coalesce(sum(spv.estoque_atual) filter (where spv.ativo), 0)::integer
  into v_estoque_total
  from public.shopping_produto_variacoes spv
  where spv.produto_id = p_produto_id;

  if coalesce(v_estoque_total, 0) > 0 then
    raise exception 'Produto disponivel para compra. Interesse so pode ser registrado para produto esgotado.';
  end if;

  insert into public.shopping_produto_interesses (
    produto_id,
    user_id
  )
  values (
    p_produto_id,
    v_user_id
  )
  on conflict on constraint shopping_produto_interesses_produto_user_unique
  do nothing
  returning id into v_interesse_id;

  if v_interesse_id is not null then
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
      v_user_id,
      'produto.interesse.registrar',
      'shopping_produto_interesses',
      v_interesse_id,
      null,
      jsonb_build_object(
        'produto_id', p_produto_id,
        'user_id', v_user_id
      ),
      'Interesse em produto esgotado registrado pela WEB-08.'
    );
  end if;

  return query
  select
    true,
    v_interesse_id is not null,
    case
      when v_interesse_id is null then 'Seu interesse neste produto já está registrado.'
      else 'Interesse registrado! A IAGO vai considerar essa demanda nas próximas encomendas.'
    end;
end;
$$;

revoke all on function public.shopping_produto_interesse_status(uuid) from public, anon, authenticated;
revoke all on function public.shopping_produto_interesse_registrar(uuid) from public, anon, authenticated;

grant execute on function public.shopping_produto_interesse_status(uuid) to authenticated;
grant execute on function public.shopping_produto_interesse_registrar(uuid) to authenticated;

comment on table public.shopping_produto_interesses is
  'Registra interesse de usuarios autenticados em produtos publicados e esgotados, preservando historico de demanda.';

comment on function public.shopping_produto_interesse_registrar(uuid) is
  'Registra interesse idempotente em produto esgotado usando auth.uid(), validando produto publicado e estoque real no servidor.';

notify pgrst, 'reload schema';
