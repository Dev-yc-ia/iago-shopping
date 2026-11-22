\set ON_ERROR_STOP on
\pset pager off
BEGIN READ ONLY;

SELECT current_database() AS banco, current_user AS papel, current_setting('server_version') AS postgres;
SELECT to_regclass('supabase_migrations.schema_migrations') AS historico_migracoes,
       to_regclass('cadastro.fotos_skatistas') AS tabela_fotos,
       to_regclass('operacao.notas_por_dia') AS visao_notas,
       to_regprocedure('cadastro.provisionar_categorias(uuid)') AS provisionador;
SELECT EXISTS (SELECT FROM cadastro.eventos WHERE codigo = :'evento') AS evento_encontrado,
       EXISTS (SELECT FROM pg_roles WHERE rolname = 'iago_runtime') AS runtime_existe;
SELECT e.codigo AS evento, c.codigo AS categoria, c.ordem, count(i.id) AS inscricoes
FROM cadastro.eventos e
LEFT JOIN cadastro.categorias c ON c.evento_id = e.id
LEFT JOIN cadastro.inscricoes i ON (i.evento_id, i.categoria_base_id) = (c.evento_id, c.id)
GROUP BY e.codigo, c.codigo, c.ordem
ORDER BY e.codigo, c.ordem;
SELECT conrelid::regclass AS tabela, conname, pg_get_constraintdef(oid) AS definicao
FROM pg_constraint
WHERE conrelid IN ('cadastro.inscricoes'::regclass, 'cadastro.categorias'::regclass)
   OR confrelid = 'cadastro.inscricoes'::regclass
ORDER BY tabela, conname;
SELECT estado, count(*) AS tentativas
FROM operacao.tentativas GROUP BY estado ORDER BY estado;
SELECT count(*) AS votos FROM operacao.votos;
SELECT count(*) AS sessoes_vigentes FROM operacao.sessoes WHERE expira_em > now();
SELECT
    EXISTS (SELECT FROM information_schema.columns WHERE table_schema='operacao'
            AND table_name='tentativas' AND column_name='dia_volta') AS dia_volta,
    EXISTS (SELECT FROM information_schema.columns WHERE table_schema='cadastro'
            AND table_name='inscricoes' AND column_name='categoria_confirmada_id') AS categoria_confirmada_legada;

COMMIT;
