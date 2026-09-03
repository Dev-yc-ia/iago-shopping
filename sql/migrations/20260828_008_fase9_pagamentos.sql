-- Fase 9 - Pagamentos.
--
-- Escopo:
-- - Payment Engine desacoplado com provedor inicial mock;
-- - simulacao local de pagamentos aprovados, recusados, pendentes, expirados e cancelados;
-- - pedido continua sendo criado a partir do carrinho sem baixa de estoque;
-- - estoque baixa somente apos confirmacao de pagamento aprovado;
-- - eventos, logs, auditoria e fila de e-mails simulada;
-- - arquitetura preparada para Mercado Pago Checkout Transparente em fase futura.

do $$
begin
  create type public.shopping_provedor_pagamento as enum ('mock', 'mercado_pago');
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  create type public.shopping_metodo_pagamento as enum ('pix', 'cartao_debito', 'cartao_credito');
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  create type public.shopping_status_pagamento as enum (
    'criado',
    'pendente',
    'aprovado',
    'recusado',
    'expirado',
    'cancelado'
  );
exception
  when duplicate_object then null;
end;
$$;

alter table public.shopping_pedidos
  add column if not exists pagamento_status public.shopping_status_pagamento not null default 'pendente',
  add column if not exists pagamento_confirmado_em timestamptz,
  add column if not exists estoque_baixado_em timestamptz;

update public.shopping_pedidos sp
set estoque_baixado_em = sp.criado_em
where sp.estoque_baixado_em is null
  and exists (
    select 1
    from public.shopping_estoque_movimentos sem
    join public.shopping_pedido_itens spi on spi.produto_id = sem.produto_id
    where spi.pedido_id = sp.id
      and sem.tipo = 'venda'::public.shopping_tipo_movimento_estoque
      and sem.motivo = 'Baixa de estoque pela finalizacao de pedido da Fase 8 do IAGO Shopping.'
  );

create table if not exists public.shopping_pagamentos (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null references public.shopping_pedidos(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  provedor public.shopping_provedor_pagamento not null default 'mock',
  metodo public.shopping_metodo_pagamento not null default 'pix',
  status public.shopping_status_pagamento not null default 'criado',
  valor numeric(12, 2) not null,
  moeda text not null default 'BRL',
  referencia_externa text not null unique,
  idempotency_key text not null unique,
  checkout_payload jsonb not null default '{}'::jsonb,
  mock_resultado public.shopping_status_pagamento,
  erro_codigo text,
  erro_mensagem text,
  expira_em timestamptz,
  processado_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_pagamentos_valor_non_negative check (valor >= 0),
  constraint shopping_pagamentos_idempotency_not_blank check (btrim(idempotency_key) <> ''),
  constraint shopping_pagamentos_referencia_not_blank check (btrim(referencia_externa) <> '')
);

create index if not exists idx_shopping_pagamentos_pedido_data
  on public.shopping_pagamentos (pedido_id, criado_em desc);

create index if not exists idx_shopping_pagamentos_user_data
  on public.shopping_pagamentos (user_id, criado_em desc);

create index if not exists idx_shopping_pagamentos_status_data
  on public.shopping_pagamentos (status, criado_em desc);

create table if not exists public.shopping_pagamento_eventos (
  id bigint generated always as identity primary key,
  pagamento_id uuid references public.shopping_pagamentos(id) on delete cascade,
  pedido_id uuid references public.shopping_pedidos(id) on delete cascade,
  provedor public.shopping_provedor_pagamento not null default 'mock',
  tipo text not null,
  status public.shopping_status_pagamento,
  payload jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  constraint shopping_pagamento_eventos_tipo_not_blank check (btrim(tipo) <> '')
);

create index if not exists idx_shopping_pagamento_eventos_pagamento
  on public.shopping_pagamento_eventos (pagamento_id, criado_em desc);

create index if not exists idx_shopping_pagamento_eventos_pedido
  on public.shopping_pagamento_eventos (pedido_id, criado_em desc);

create table if not exists public.shopping_pagamento_logs (
  id bigint generated always as identity primary key,
  pagamento_id uuid references public.shopping_pagamentos(id) on delete set null,
  pedido_id uuid references public.shopping_pedidos(id) on delete set null,
  nivel text not null default 'info',
  mensagem text not null,
  contexto jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  constraint shopping_pagamento_logs_nivel_not_blank check (btrim(nivel) <> ''),
  constraint shopping_pagamento_logs_mensagem_not_blank check (btrim(mensagem) <> '')
);

create index if not exists idx_shopping_pagamento_logs_data
  on public.shopping_pagamento_logs (criado_em desc);

create table if not exists public.shopping_email_fila (
  id bigint generated always as identity primary key,
  pedido_id uuid references public.shopping_pedidos(id) on delete cascade,
  pagamento_id uuid references public.shopping_pagamentos(id) on delete cascade,
  destinatario_tipo text not null,
  destinatario_email text,
  assunto text not null,
  corpo text not null,
  status text not null default 'simulado',
  payload jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  constraint shopping_email_fila_destinatario_tipo_not_blank check (btrim(destinatario_tipo) <> ''),
  constraint shopping_email_fila_assunto_not_blank check (btrim(assunto) <> ''),
  constraint shopping_email_fila_corpo_not_blank check (btrim(corpo) <> '')
);

create index if not exists idx_shopping_email_fila_pedido
  on public.shopping_email_fila (pedido_id, criado_em desc);

drop trigger if exists trg_shopping_pagamentos_touch on public.shopping_pagamentos;
create trigger trg_shopping_pagamentos_touch
before update on public.shopping_pagamentos
for each row execute function public.shopping_touch_atualizado_em();

alter table public.shopping_pagamentos enable row level security;
alter table public.shopping_pagamento_eventos enable row level security;
alter table public.shopping_pagamento_logs enable row level security;
alter table public.shopping_email_fila enable row level security;

drop policy if exists shopping_pagamentos_select_own_or_admin on public.shopping_pagamentos;
create policy shopping_pagamentos_select_own_or_admin
on public.shopping_pagamentos
for select
to authenticated
using (
  user_id = auth.uid()
  or public.shopping_is_admin(auth.uid())
);

drop policy if exists shopping_pagamento_eventos_select_own_or_admin on public.shopping_pagamento_eventos;
create policy shopping_pagamento_eventos_select_own_or_admin
on public.shopping_pagamento_eventos
for select
to authenticated
using (
  exists (
    select 1
    from public.shopping_pagamentos sp
    where sp.id = pagamento_id
      and (
        sp.user_id = auth.uid()
        or public.shopping_is_admin(auth.uid())
      )
  )
  or public.shopping_is_admin(auth.uid())
);

drop policy if exists shopping_pagamento_logs_select_admin on public.shopping_pagamento_logs;
create policy shopping_pagamento_logs_select_admin
on public.shopping_pagamento_logs
for select
to authenticated
using (public.shopping_is_admin(auth.uid()));

drop policy if exists shopping_email_fila_select_admin on public.shopping_email_fila;
create policy shopping_email_fila_select_admin
on public.shopping_email_fila
for select
to authenticated
using (public.shopping_is_admin(auth.uid()));

revoke all on public.shopping_pagamentos from anon, authenticated;
revoke all on public.shopping_pagamento_eventos from anon, authenticated;
revoke all on public.shopping_pagamento_logs from anon, authenticated;
revoke all on public.shopping_email_fila from anon, authenticated;

grant select on public.shopping_pagamentos to authenticated;
grant select on public.shopping_pagamento_eventos to authenticated;
grant select on public.shopping_pagamento_logs to authenticated;
grant select on public.shopping_email_fila to authenticated;

create or replace function public.shopping_pagamento_registrar_evento(
  p_pagamento_id uuid,
  p_pedido_id uuid,
  p_tipo text,
  p_status public.shopping_status_pagamento,
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.shopping_pagamento_eventos (
    pagamento_id,
    pedido_id,
    tipo,
    status,
    payload
  )
  values (
    p_pagamento_id,
    p_pedido_id,
    p_tipo,
    p_status,
    coalesce(p_payload, '{}'::jsonb)
  );

  insert into public.shopping_pagamento_logs (
    pagamento_id,
    pedido_id,
    nivel,
    mensagem,
    contexto
  )
  values (
    p_pagamento_id,
    p_pedido_id,
    'info',
    p_tipo,
    jsonb_build_object('status', p_status, 'payload', coalesce(p_payload, '{}'::jsonb))
  );
end;
$$;

create or replace function public.shopping_pagamento_enfileirar_emails(
  p_pagamento_id uuid,
  p_pedido_id uuid,
  p_status public.shopping_status_pagamento
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pedido public.shopping_pedidos;
  v_assunto text;
  v_corpo text;
begin
  select *
  into v_pedido
  from public.shopping_pedidos sp
  where sp.id = p_pedido_id;

  if v_pedido.id is null then
    return;
  end if;

  v_assunto := case p_status
    when 'aprovado'::public.shopping_status_pagamento then 'Pagamento aprovado no IAGO Shopping'
    when 'recusado'::public.shopping_status_pagamento then 'Pagamento recusado no IAGO Shopping'
    when 'expirado'::public.shopping_status_pagamento then 'Pagamento expirado no IAGO Shopping'
    when 'cancelado'::public.shopping_status_pagamento then 'Pagamento cancelado no IAGO Shopping'
    else 'Pagamento pendente no IAGO Shopping'
  end;

  v_corpo := 'Pedido #' || v_pedido.numero || ' - status do pagamento: ' || p_status::text || '.';

  insert into public.shopping_email_fila (
    pedido_id,
    pagamento_id,
    destinatario_tipo,
    destinatario_email,
    assunto,
    corpo,
    payload
  )
  values
    (
      p_pedido_id,
      p_pagamento_id,
      'cliente',
      v_pedido.cliente_email,
      v_assunto,
      v_corpo,
      jsonb_build_object('pedido_numero', v_pedido.numero, 'status_pagamento', p_status)
    ),
    (
      p_pedido_id,
      p_pagamento_id,
      'admin',
      null,
      '[Admin] ' || v_assunto,
      v_corpo,
      jsonb_build_object('pedido_numero', v_pedido.numero, 'status_pagamento', p_status)
    );
end;
$$;

create or replace function public.shopping_pagamento_baixar_estoque_pedido(p_pedido_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pedido public.shopping_pedidos;
  v_item public.shopping_pedido_itens;
  v_variacao public.shopping_produto_variacoes;
  v_saldo_anterior integer;
begin
  select *
  into v_pedido
  from public.shopping_pedidos sp
  where sp.id = p_pedido_id
  for update;

  if v_pedido.id is null then
    raise exception 'Pedido nao encontrado para baixa de estoque.';
  end if;

  if v_pedido.estoque_baixado_em is not null then
    return;
  end if;

  for v_item in
    select *
    from public.shopping_pedido_itens spi
    where spi.pedido_id = v_pedido.id
    order by spi.criado_em, spi.id
  loop
    select *
    into v_variacao
    from public.shopping_produto_variacoes spv
    where spv.id = v_item.variacao_id
      and spv.ativo
    for update;

    if v_variacao.id is null then
      select *
      into v_variacao
      from public.shopping_produto_variacoes spv
      where spv.produto_id = v_item.produto_id
        and spv.ativo
      order by spv.principal desc, spv.id
      limit 1
      for update;
    end if;

    if v_variacao.id is null then
      raise exception 'Produto sem variacao de estoque para pagamento.';
    end if;

    if v_variacao.estoque_atual < v_item.quantidade then
      raise exception 'Estoque insuficiente para confirmar pagamento.';
    end if;

    v_saldo_anterior := v_variacao.estoque_atual;

    update public.shopping_produto_variacoes
    set estoque_atual = estoque_atual - v_item.quantidade,
        atualizado_por = v_pedido.user_id
    where id = v_variacao.id
      and estoque_atual >= v_item.quantidade
    returning * into v_variacao;

    if v_variacao.id is null then
      raise exception 'Estoque mudou durante a confirmacao do pagamento.';
    end if;

    update public.shopping_pedido_itens
    set variacao_id = v_variacao.id
    where id = v_item.id
      and variacao_id is distinct from v_variacao.id;

    insert into public.shopping_estoque_movimentos (
      variacao_id,
      produto_id,
      tipo,
      quantidade,
      saldo_anterior,
      saldo_posterior,
      motivo,
      criado_por
    )
    values (
      v_variacao.id,
      v_item.produto_id,
      'venda'::public.shopping_tipo_movimento_estoque,
      -v_item.quantidade,
      v_saldo_anterior,
      v_variacao.estoque_atual,
      'Baixa de estoque pela confirmacao de pagamento da Fase 9 do IAGO Shopping.',
      v_pedido.user_id
    );
  end loop;

  update public.shopping_pedidos
  set estoque_baixado_em = now()
  where id = v_pedido.id;
end;
$$;

create or replace function public.shopping_pagamento_reverter_estoque_pedido(p_pedido_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pedido public.shopping_pedidos;
  v_item public.shopping_pedido_itens;
  v_variacao public.shopping_produto_variacoes;
  v_saldo_anterior integer;
begin
  select *
  into v_pedido
  from public.shopping_pedidos sp
  where sp.id = p_pedido_id
  for update;

  if v_pedido.id is null or v_pedido.estoque_baixado_em is null then
    return;
  end if;

  if v_pedido.pagamento_status = 'aprovado'::public.shopping_status_pagamento then
    return;
  end if;

  for v_item in
    select *
    from public.shopping_pedido_itens spi
    where spi.pedido_id = v_pedido.id
    order by spi.criado_em, spi.id
  loop
    select *
    into v_variacao
    from public.shopping_produto_variacoes spv
    where spv.id = v_item.variacao_id
    for update;

    if v_variacao.id is null then
      continue;
    end if;

    v_saldo_anterior := v_variacao.estoque_atual;

    update public.shopping_produto_variacoes
    set estoque_atual = estoque_atual + v_item.quantidade,
        atualizado_por = v_pedido.user_id
    where id = v_variacao.id
    returning * into v_variacao;

    insert into public.shopping_estoque_movimentos (
      variacao_id,
      produto_id,
      tipo,
      quantidade,
      saldo_anterior,
      saldo_posterior,
      motivo,
      criado_por
    )
    values (
      v_variacao.id,
      v_item.produto_id,
      'cancelamento'::public.shopping_tipo_movimento_estoque,
      v_item.quantidade,
      v_saldo_anterior,
      v_variacao.estoque_atual,
      'Estorno de estoque por pagamento nao aprovado na Fase 9 do IAGO Shopping.',
      v_pedido.user_id
    );
  end loop;

  update public.shopping_pedidos
  set estoque_baixado_em = null
  where id = v_pedido.id;
end;
$$;

create or replace function public.shopping_pedido_finalizar_carrinho()
returns public.shopping_pedidos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_perfil public.shopping_perfis;
  v_carrinho public.shopping_carrinhos;
  v_pedido public.shopping_pedidos;
  v_item record;
  v_variacao public.shopping_produto_variacoes;
  v_total numeric(12, 2);
  v_total_itens integer;
begin
  select *
  into v_perfil
  from public.shopping_perfis sp
  where sp.user_id = v_user_id
  limit 1;

  select *
  into v_carrinho
  from public.shopping_carrinhos sc
  where sc.user_id = v_user_id
    and sc.status = 'ativo'::public.shopping_status_carrinho
  for update;

  if v_carrinho.id is null then
    raise exception 'Carrinho ativo nao encontrado para finalizar pedido.';
  end if;

  select
    count(*)::integer,
    coalesce(sum(sci.preco_unitario * sci.quantidade), 0)::numeric(12, 2)
  into v_total_itens, v_total
  from public.shopping_carrinho_itens sci
  where sci.carrinho_id = v_carrinho.id;

  if v_total_itens = 0 then
    raise exception 'Carrinho vazio nao pode gerar pedido.';
  end if;

  insert into public.shopping_pedidos (
    user_id,
    perfil_id,
    carrinho_id,
    status,
    pagamento_status,
    cliente_nome,
    cliente_email,
    subtotal,
    total
  )
  values (
    v_user_id,
    v_perfil.id,
    v_carrinho.id,
    'pendente_pagamento'::public.shopping_status_pedido,
    'pendente'::public.shopping_status_pagamento,
    v_perfil.nome_exibicao,
    v_perfil.email_normalizado,
    v_total,
    v_total
  )
  returning * into v_pedido;

  for v_item in
    select
      sci.produto_id,
      sci.quantidade,
      sci.preco_unitario,
      sp.sku,
      sp.nome,
      sp.marca,
      sp.categoria,
      sp.status,
      si.imagem_url
    from public.shopping_carrinho_itens sci
    join public.shopping_produtos sp on sp.id = sci.produto_id
    left join lateral (
      select spi.url as imagem_url
      from public.shopping_produto_imagens spi
      where spi.produto_id = sp.id
      order by spi.principal desc, spi.ordem, spi.id
      limit 1
    ) si on true
    where sci.carrinho_id = v_carrinho.id
    order by sci.criado_em, sci.id
  loop
    if v_item.status <> 'publicado'::public.shopping_status_produto then
      raise exception 'Produto indisponivel para gerar pedido.';
    end if;

    select *
    into v_variacao
    from public.shopping_produto_variacoes spv
    where spv.produto_id = v_item.produto_id
      and spv.ativo
    order by spv.principal desc, spv.id
    limit 1
    for update;

    if v_variacao.id is null then
      raise exception 'Produto sem variacao de estoque para pedido.';
    end if;

    if v_variacao.estoque_atual < v_item.quantidade then
      raise exception 'Quantidade solicitada maior que o estoque disponivel.';
    end if;

    insert into public.shopping_pedido_itens (
      pedido_id,
      produto_id,
      variacao_id,
      sku,
      nome,
      marca,
      categoria,
      imagem_url,
      quantidade,
      preco_unitario,
      subtotal
    )
    values (
      v_pedido.id,
      v_item.produto_id,
      v_variacao.id,
      v_item.sku,
      v_item.nome,
      v_item.marca,
      v_item.categoria,
      v_item.imagem_url,
      v_item.quantidade,
      v_item.preco_unitario,
      (v_item.preco_unitario * v_item.quantidade)::numeric(12, 2)
    );
  end loop;

  update public.shopping_carrinhos
  set status = 'convertido'::public.shopping_status_carrinho
  where id = v_carrinho.id;

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
    auth.uid(),
    'pedido.finalizar',
    'shopping_pedidos',
    v_pedido.id,
    jsonb_build_object('carrinho_id', v_carrinho.id),
    to_jsonb(v_pedido),
    'Pedido criado a partir do carrinho ativo pela Fase 9, sem baixa de estoque antes do pagamento.'
  );

  return v_pedido;
end;
$$;

create or replace function public.shopping_pagamento_mock_criar(
  p_pedido_id uuid,
  p_metodo public.shopping_metodo_pagamento default 'pix'
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_pedido public.shopping_pedidos;
  v_pagamento public.shopping_pagamentos;
  v_idempotency_key text;
begin
  select *
  into v_pedido
  from public.shopping_pedidos sp
  where sp.id = p_pedido_id
    and sp.user_id = v_user_id
  for update;

  if v_pedido.id is null then
    raise exception 'Pedido nao encontrado para pagamento.';
  end if;

  if v_pedido.pagamento_status = 'aprovado'::public.shopping_status_pagamento then
    raise exception 'Pedido ja possui pagamento aprovado.';
  end if;

  select *
  into v_pagamento
  from public.shopping_pagamentos sp
  where sp.pedido_id = v_pedido.id
    and sp.status in ('criado'::public.shopping_status_pagamento, 'pendente'::public.shopping_status_pagamento)
  order by sp.criado_em desc
  limit 1;

  if v_pagamento.id is not null then
    return v_pagamento;
  end if;

  v_idempotency_key := 'mock:' || v_pedido.id::text || ':' || coalesce(p_metodo::text, 'pix') || ':' || extract(epoch from date_trunc('second', now()))::bigint::text;

  insert into public.shopping_pagamentos (
    pedido_id,
    user_id,
    provedor,
    metodo,
    status,
    valor,
    moeda,
    referencia_externa,
    idempotency_key,
    checkout_payload,
    expira_em
  )
  values (
    v_pedido.id,
    v_user_id,
    'mock'::public.shopping_provedor_pagamento,
    coalesce(p_metodo, 'pix'::public.shopping_metodo_pagamento),
    'pendente'::public.shopping_status_pagamento,
    v_pedido.total,
    v_pedido.moeda,
    'mock_' || replace(gen_random_uuid()::text, '-', ''),
    v_idempotency_key,
    jsonb_build_object(
      'engine', 'mock',
      'provider_future', 'mercado_pago',
      'methods_future', jsonb_build_array('pix', 'cartao_debito', 'cartao_credito'),
      'message', 'Pagamento mock criado para testes locais.'
    ),
    now() + interval '30 minutes'
  )
  returning * into v_pagamento;

  update public.shopping_pedidos
  set pagamento_status = 'pendente'::public.shopping_status_pagamento
  where id = v_pedido.id;

  perform public.shopping_pagamento_registrar_evento(
    v_pagamento.id,
    v_pedido.id,
    'payment.mock.created',
    v_pagamento.status,
    to_jsonb(v_pagamento)
  );

  perform public.shopping_pagamento_enfileirar_emails(v_pagamento.id, v_pedido.id, v_pagamento.status);

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
    auth.uid(),
    'pagamento.mock.criar',
    'shopping_pagamentos',
    v_pagamento.id,
    null,
    to_jsonb(v_pagamento),
    'Pagamento mock criado pela Fase 9 do IAGO Shopping.'
  );

  return v_pagamento;
end;
$$;

create or replace function public.shopping_pagamento_mock_simular(
  p_pagamento_id uuid,
  p_resultado public.shopping_status_pagamento,
  p_payload jsonb default '{}'::jsonb
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_pagamento public.shopping_pagamentos;
  v_pagamento_antes jsonb;
begin
  if p_resultado not in (
    'aprovado'::public.shopping_status_pagamento,
    'recusado'::public.shopping_status_pagamento,
    'pendente'::public.shopping_status_pagamento,
    'expirado'::public.shopping_status_pagamento,
    'cancelado'::public.shopping_status_pagamento
  ) then
    raise exception 'Resultado mock invalido para pagamento.';
  end if;

  select *
  into v_pagamento
  from public.shopping_pagamentos sp
  where sp.id = p_pagamento_id
    and (
      sp.user_id = v_user_id
      or public.shopping_is_admin(v_user_id)
    )
  for update;

  if v_pagamento.id is null then
    raise exception 'Pagamento nao encontrado para simulacao.';
  end if;

  if v_pagamento.provedor <> 'mock'::public.shopping_provedor_pagamento then
    raise exception 'Somente pagamentos mock podem ser simulados localmente.';
  end if;

  if v_pagamento.status = 'aprovado'::public.shopping_status_pagamento
    and p_resultado = 'aprovado'::public.shopping_status_pagamento then
    return v_pagamento;
  end if;

  if v_pagamento.status = 'aprovado'::public.shopping_status_pagamento
    and p_resultado <> 'aprovado'::public.shopping_status_pagamento then
    raise exception 'Pagamento aprovado nao pode voltar para outro status.';
  end if;

  v_pagamento_antes := to_jsonb(v_pagamento);

  update public.shopping_pagamentos
  set status = p_resultado,
      mock_resultado = p_resultado,
      erro_codigo = case
        when p_resultado in ('recusado'::public.shopping_status_pagamento, 'expirado'::public.shopping_status_pagamento, 'cancelado'::public.shopping_status_pagamento)
          then 'mock_' || p_resultado::text
        else null
      end,
      erro_mensagem = case
        when p_resultado = 'recusado'::public.shopping_status_pagamento then 'Pagamento recusado na simulacao mock.'
        when p_resultado = 'expirado'::public.shopping_status_pagamento then 'Pagamento expirado na simulacao mock.'
        when p_resultado = 'cancelado'::public.shopping_status_pagamento then 'Pagamento cancelado na simulacao mock.'
        else null
      end,
      processado_em = case
        when p_resultado = 'pendente'::public.shopping_status_pagamento then processado_em
        else now()
      end,
      checkout_payload = checkout_payload || coalesce(p_payload, '{}'::jsonb)
  where id = v_pagamento.id
  returning * into v_pagamento;

  if p_resultado = 'aprovado'::public.shopping_status_pagamento then
    perform public.shopping_pagamento_baixar_estoque_pedido(v_pagamento.pedido_id);

    update public.shopping_pedidos
    set pagamento_status = 'aprovado'::public.shopping_status_pagamento,
        pagamento_confirmado_em = coalesce(v_pagamento.processado_em, now())
    where id = v_pagamento.pedido_id;
  elsif p_resultado in (
    'recusado'::public.shopping_status_pagamento,
    'expirado'::public.shopping_status_pagamento,
    'cancelado'::public.shopping_status_pagamento
  ) then
    update public.shopping_pedidos
    set pagamento_status = p_resultado
    where id = v_pagamento.pedido_id;

    perform public.shopping_pagamento_reverter_estoque_pedido(v_pagamento.pedido_id);
  else
    update public.shopping_pedidos
    set pagamento_status = 'pendente'::public.shopping_status_pagamento
    where id = v_pagamento.pedido_id;
  end if;

  perform public.shopping_pagamento_registrar_evento(
    v_pagamento.id,
    v_pagamento.pedido_id,
    'payment.mock.' || p_resultado::text,
    p_resultado,
    coalesce(p_payload, '{}'::jsonb)
  );

  perform public.shopping_pagamento_enfileirar_emails(v_pagamento.id, v_pagamento.pedido_id, p_resultado);

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
    auth.uid(),
    'pagamento.mock.simular',
    'shopping_pagamentos',
    v_pagamento.id,
    v_pagamento_antes,
    to_jsonb(v_pagamento),
    'Resultado de pagamento mock processado pela Fase 9 do IAGO Shopping.'
  );

  select *
  into v_pagamento
  from public.shopping_pagamentos sp
  where sp.id = p_pagamento_id;

  return v_pagamento;
end;
$$;

drop function if exists public.shopping_pedidos_cliente_listar();

create or replace function public.shopping_pedidos_cliente_listar()
returns table (
  id uuid,
  numero bigint,
  status public.shopping_status_pedido,
  pagamento_status public.shopping_status_pagamento,
  pagamento_id uuid,
  pagamento_provedor public.shopping_provedor_pagamento,
  pagamento_metodo public.shopping_metodo_pagamento,
  total numeric,
  moeda text,
  itens jsonb,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    sp.id,
    sp.numero,
    sp.status,
    sp.pagamento_status,
    spl.pagamento_id,
    spl.pagamento_provedor,
    spl.pagamento_metodo,
    sp.total,
    sp.moeda,
    coalesce(si.itens, '[]'::jsonb) as itens,
    sp.criado_em,
    sp.atualizado_em
  from public.shopping_pedidos sp
  left join lateral (
    select
      pg.id as pagamento_id,
      pg.provedor as pagamento_provedor,
      pg.metodo as pagamento_metodo
    from public.shopping_pagamentos pg
    where pg.pedido_id = sp.id
    order by pg.criado_em desc
    limit 1
  ) spl on true
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'item_id', spi.id,
        'produto_id', spi.produto_id,
        'sku', spi.sku,
        'nome', spi.nome,
        'marca', spi.marca,
        'categoria', spi.categoria,
        'imagem_url', spi.imagem_url,
        'quantidade', spi.quantidade,
        'preco_unitario', spi.preco_unitario,
        'subtotal', spi.subtotal
      )
      order by spi.criado_em, spi.id
    ) as itens
    from public.shopping_pedido_itens spi
    where spi.pedido_id = sp.id
  ) si on true
  where sp.user_id = auth.uid()
  order by sp.criado_em desc, sp.numero desc;
$$;

drop function if exists public.shopping_admin_listar_pedidos();

create or replace function public.shopping_admin_listar_pedidos()
returns table (
  id uuid,
  numero bigint,
  status public.shopping_status_pedido,
  pagamento_status public.shopping_status_pagamento,
  pagamento_id uuid,
  pagamento_provedor public.shopping_provedor_pagamento,
  pagamento_metodo public.shopping_metodo_pagamento,
  cliente_nome text,
  cliente_email text,
  total numeric,
  moeda text,
  itens jsonb,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
begin
  return query
  select
    sp.id,
    sp.numero,
    sp.status,
    sp.pagamento_status,
    spl.pagamento_id,
    spl.pagamento_provedor,
    spl.pagamento_metodo,
    sp.cliente_nome,
    sp.cliente_email,
    sp.total,
    sp.moeda,
    coalesce(si.itens, '[]'::jsonb) as itens,
    sp.criado_em,
    sp.atualizado_em
  from public.shopping_pedidos sp
  left join lateral (
    select
      pg.id as pagamento_id,
      pg.provedor as pagamento_provedor,
      pg.metodo as pagamento_metodo
    from public.shopping_pagamentos pg
    where pg.pedido_id = sp.id
    order by pg.criado_em desc
    limit 1
  ) spl on true
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'item_id', spi.id,
        'sku', spi.sku,
        'nome', spi.nome,
        'marca', spi.marca,
        'categoria', spi.categoria,
        'quantidade', spi.quantidade,
        'preco_unitario', spi.preco_unitario,
        'subtotal', spi.subtotal
      )
      order by spi.criado_em, spi.id
    ) as itens
    from public.shopping_pedido_itens spi
    where spi.pedido_id = sp.id
  ) si on true
  order by sp.criado_em desc, sp.numero desc;
end;
$$;

create or replace function public.shopping_admin_listar_pagamentos()
returns table (
  id uuid,
  pedido_id uuid,
  pedido_numero bigint,
  cliente_nome text,
  cliente_email text,
  provedor public.shopping_provedor_pagamento,
  metodo public.shopping_metodo_pagamento,
  status public.shopping_status_pagamento,
  valor numeric,
  moeda text,
  referencia_externa text,
  eventos integer,
  emails integer,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
begin
  return query
  select
    pg.id,
    pg.pedido_id,
    sp.numero,
    sp.cliente_nome,
    sp.cliente_email,
    pg.provedor,
    pg.metodo,
    pg.status,
    pg.valor,
    pg.moeda,
    pg.referencia_externa,
    coalesce(pe.total_eventos, 0)::integer as eventos,
    coalesce(em.total_emails, 0)::integer as emails,
    pg.criado_em,
    pg.atualizado_em
  from public.shopping_pagamentos pg
  join public.shopping_pedidos sp on sp.id = pg.pedido_id
  left join lateral (
    select count(*)::integer as total_eventos
    from public.shopping_pagamento_eventos spe
    where spe.pagamento_id = pg.id
  ) pe on true
  left join lateral (
    select count(*)::integer as total_emails
    from public.shopping_email_fila sef
    where sef.pagamento_id = pg.id
  ) em on true
  order by pg.criado_em desc, pg.atualizado_em desc;
end;
$$;

revoke all on function public.shopping_pagamento_registrar_evento(uuid, uuid, text, public.shopping_status_pagamento, jsonb) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_enfileirar_emails(uuid, uuid, public.shopping_status_pagamento) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_baixar_estoque_pedido(uuid) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_reverter_estoque_pedido(uuid) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_mock_criar(uuid, public.shopping_metodo_pagamento) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_mock_simular(uuid, public.shopping_status_pagamento, jsonb) from public, anon, authenticated;
revoke all on function public.shopping_pedido_finalizar_carrinho() from public, anon, authenticated;
revoke all on function public.shopping_pedidos_cliente_listar() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_pedidos() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_pagamentos() from public, anon, authenticated;

grant execute on function public.shopping_pedido_finalizar_carrinho() to authenticated;
grant execute on function public.shopping_pedidos_cliente_listar() to authenticated;
grant execute on function public.shopping_admin_listar_pedidos() to authenticated;
grant execute on function public.shopping_pagamento_mock_criar(uuid, public.shopping_metodo_pagamento) to authenticated;
grant execute on function public.shopping_pagamento_mock_simular(uuid, public.shopping_status_pagamento, jsonb) to authenticated;
grant execute on function public.shopping_admin_listar_pagamentos() to authenticated;

comment on table public.shopping_pagamentos is
  'Registro de tentativas de pagamento do Payment Engine. Provedor inicial: mock.';

comment on table public.shopping_pagamento_eventos is
  'Eventos normalizados de pagamento, incluindo simulacoes mock e futuros webhooks.';

comment on table public.shopping_pagamento_logs is
  'Log operacional do Payment Engine para auditoria tecnica.';

comment on table public.shopping_email_fila is
  'Fila de e-mails simulada da Fase 9 para cliente e administradores.';

comment on function public.shopping_pagamento_mock_criar(uuid, public.shopping_metodo_pagamento) is
  'Cria uma tentativa de pagamento mock para pedido do usuario autenticado.';

comment on function public.shopping_pagamento_mock_simular(uuid, public.shopping_status_pagamento, jsonb) is
  'Simula retorno de pagamento mock com as mesmas regras de producao.';

comment on function public.shopping_pagamento_baixar_estoque_pedido(uuid) is
  'Baixa estoque apenas apos confirmacao de pagamento aprovado.';
