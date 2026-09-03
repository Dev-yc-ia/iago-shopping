-- IAGO Shopping - Fase 6
-- Storage publico para fotos principais de produtos.
--
-- Escopo:
-- - bucket publico para imagens de produtos publicados no catalogo;
-- - upload, atualizacao e remocao restritos a usuarios administrativos ativos;
-- - leitura publica das imagens para o catalogo;
-- - sem alterar credenciais ou criar mecanismo paralelo de configuracao.

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'shopping-produtos',
  'shopping-produtos',
  true,
  5242880,
  array[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif'
  ]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists shopping_produtos_storage_select_public on storage.objects;
create policy shopping_produtos_storage_select_public
on storage.objects
for select
to anon, authenticated
using (bucket_id = 'shopping-produtos');

drop policy if exists shopping_produtos_storage_insert_admin on storage.objects;
create policy shopping_produtos_storage_insert_admin
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'shopping-produtos'
  and public.shopping_is_admin(auth.uid())
);

drop policy if exists shopping_produtos_storage_update_admin on storage.objects;
create policy shopping_produtos_storage_update_admin
on storage.objects
for update
to authenticated
using (
  bucket_id = 'shopping-produtos'
  and public.shopping_is_admin(auth.uid())
)
with check (
  bucket_id = 'shopping-produtos'
  and public.shopping_is_admin(auth.uid())
);

drop policy if exists shopping_produtos_storage_delete_admin on storage.objects;
create policy shopping_produtos_storage_delete_admin
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'shopping-produtos'
  and public.shopping_is_admin(auth.uid())
);

comment on policy shopping_produtos_storage_select_public on storage.objects is
  'Permite leitura publica das fotos de produtos exibidas no catalogo.';

comment on policy shopping_produtos_storage_insert_admin on storage.objects is
  'Permite upload de fotos de produtos somente para perfis administrativos ativos.';
