-- IAGO Shopping - Bootstrap controlado do primeiro master
--
-- Execute este script manualmente no SQL Editor do projeto Supabase
-- depois que a migração Fase 1 tiver sido aplicada e depois que a conta
-- do primeiro master existir no Supabase Auth.
--
-- Substitua os valores abaixo:
-- - INFORMAR_UUID_AUTH_USERS: auth.users.id da conta que será master;
-- - informar_email_normalizado@exemplo.com: e-mail normalizado da mesma conta;
-- - Nome Master: nome exibido no Shopping.
--
-- Não use este script no navegador da aplicação.
-- Não informe senha aqui. Senhas ficam somente no Supabase Auth.

select public.shopping_bootstrap_primeiro_master(
  p_user_id := 'INFORMAR_UUID_AUTH_USERS'::uuid,
  p_email_normalizado := 'informar_email_normalizado@exemplo.com',
  p_nome_exibicao := 'Nome Master'
);
