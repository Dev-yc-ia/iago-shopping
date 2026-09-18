-- IAGO Shopping - WEB-19
-- Cadastro obrigatorio antes da finalizacao do carrinho.

create or replace function public.shopping_pedido_finalizar_carrinho()
returns public.shopping_pedidos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_perfil public.shopping_perfis;
  v_endereco_reg public.shopping_enderecos;
  v_endereco jsonb;
  v_carrinho public.shopping_carrinhos;
  v_pedido public.shopping_pedidos;
  v_item record;
  v_variacao public.shopping_produto_variacoes;
  v_total numeric(12, 2);
  v_total_itens integer;
  v_telefone_digits text;
  v_cep_digits text;
begin
  select *
  into v_perfil
  from public.shopping_perfis sp
  where sp.user_id = v_user_id
  limit 1;

  select *
  into v_endereco_reg
  from public.shopping_enderecos se
  where se.user_id = v_user_id
    and se.padrao
  order by se.atualizado_em desc, se.id
  limit 1;

  v_telefone_digits := regexp_replace(coalesce(v_perfil.telefone_normalizado, ''), '\D', '', 'g');
  v_cep_digits := regexp_replace(coalesce(v_endereco_reg.cep, ''), '\D', '', 'g');

  if v_perfil.id is null
    or btrim(coalesce(v_perfil.nome_completo, '')) = ''
    or btrim(coalesce(v_perfil.email_normalizado, '')) = ''
    or char_length(v_telefone_digits) < 10
    or regexp_replace(v_telefone_digits, '0', '', 'g') = ''
    or v_endereco_reg.id is null
    or btrim(coalesce(v_endereco_reg.nome_destinatario, '')) = ''
    or char_length(v_cep_digits) <> 8
    or btrim(coalesce(v_endereco_reg.logradouro, '')) = ''
    or btrim(coalesce(v_endereco_reg.numero, '')) = ''
    or btrim(coalesce(v_endereco_reg.bairro, '')) = ''
    or btrim(coalesce(v_endereco_reg.cidade, '')) = ''
    or upper(btrim(coalesce(v_endereco_reg.uf, ''))) !~ '^[A-Z]{2}$'
  then
    raise exception 'Complete seus dados pessoais e endereço de entrega antes de finalizar o pedido.';
  end if;

  v_endereco := to_jsonb(v_endereco_reg) - 'id' - 'user_id' - 'criado_em' - 'atualizado_em';

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

  if exists (
    select 1
    from public.shopping_carrinho_itens sci
    join public.shopping_produtos sp on sp.id = sci.produto_id
    left join public.shopping_perfis spar on spar.user_id = sp.parceiro_user_id
    where sci.carrinho_id = v_carrinho.id
      and (
        sp.status <> 'publicado'::public.shopping_status_produto
        or sp.parceiro_user_id is null
        or sp.valor_repasse_parceiro is null
        or sp.valor_repasse_parceiro < 0
        or sp.valor_repasse_parceiro > sp.preco
        or spar.user_id is null
        or spar.papel <> 'parceiro'::public.shopping_papel
        or spar.status_ativacao <> 'ativo'::public.shopping_status_ativacao
      )
  ) then
    raise exception 'Um item do carrinho ainda nao esta configurado para entrega pelo parceiro. Remova o item ou fale com a IAGO.';
  end if;

  insert into public.shopping_pedidos (
    user_id,
    perfil_id,
    carrinho_id,
    status,
    pagamento_status,
    fulfillment_status,
    cliente_nome,
    cliente_email,
    endereco_entrega_snapshot,
    subtotal,
    total
  )
  values (
    v_user_id,
    v_perfil.id,
    v_carrinho.id,
    'pendente_pagamento'::public.shopping_status_pedido,
    'pendente'::public.shopping_status_pagamento,
    'pendente_pagamento',
    v_perfil.nome_exibicao,
    v_perfil.email_normalizado,
    v_endereco,
    v_total,
    v_total
  )
  returning * into v_pedido;

  for v_item in
    select
      sci.produto_id,
      sci.variacao_id,
      sci.quantidade,
      sci.preco_unitario,
      sp.sku,
      sp.nome,
      sp.marca,
      sp.categoria,
      sp.status,
      sp.parceiro_user_id,
      sp.valor_repasse_parceiro,
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
    select *
    into v_variacao
    from public.shopping_produto_variacoes spv
    where spv.id = v_item.variacao_id
      and spv.produto_id = v_item.produto_id
      and spv.ativo
    for update;

    if v_variacao.id is null then
      raise exception 'Variacao do carrinho indisponivel para pedido.';
    end if;

    if v_variacao.estoque_atual < v_item.quantidade then
      raise exception 'Quantidade solicitada maior que o estoque da variacao.';
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
      subtotal,
      parceiro_user_id_snapshot,
      valor_repasse_unitario_snapshot,
      valor_repasse_total_snapshot
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
      (v_item.preco_unitario * v_item.quantidade)::numeric(12, 2),
      v_item.parceiro_user_id,
      v_item.valor_repasse_parceiro,
      (v_item.valor_repasse_parceiro * v_item.quantidade)::numeric(12, 2)
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
    'Pedido criado pela WEB-19 com cadastro minimo de contato e entrega validado.'
  );

  return v_pedido;
end;
$$;

revoke all on function public.shopping_pedido_finalizar_carrinho() from public, anon, authenticated;
grant execute on function public.shopping_pedido_finalizar_carrinho() to authenticated;

comment on function public.shopping_pedido_finalizar_carrinho() is
  'Finaliza o carrinho ativo em pedido somente quando o cliente possui cadastro minimo de contato e endereco de entrega.';
