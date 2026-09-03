-- Fase 9 - Compatibilidade da RPC de criacao de pagamento mock.
-- Mantem a arquitetura principal da Fase 9 e cria uma entrada estavel para o frontend.

create or replace function public.shopping_pagamento_mock_criar_rpc(
  p_pedido_id uuid,
  p_metodo text default 'pix'
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_metodo public.shopping_metodo_pagamento;
begin
  begin
    v_metodo := coalesce(nullif(btrim(p_metodo), ''), 'pix')::public.shopping_metodo_pagamento;
  exception
    when invalid_text_representation then
      raise exception 'Metodo de pagamento invalido para o Mock.';
  end;

  return public.shopping_pagamento_mock_criar(p_pedido_id, v_metodo);
end;
$$;

revoke all on function public.shopping_pagamento_mock_criar_rpc(uuid, text) from public, anon, authenticated;
grant execute on function public.shopping_pagamento_mock_criar_rpc(uuid, text) to authenticated;

comment on function public.shopping_pagamento_mock_criar_rpc(uuid, text) is
  'Wrapper RPC estavel para criar pagamento mock com metodo em texto no IAGO Shopping.';

notify pgrst, 'reload schema';
