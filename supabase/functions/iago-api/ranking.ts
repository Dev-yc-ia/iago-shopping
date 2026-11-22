import type postgres from "npm:postgres@3.4.7";

export async function ranking(sql: ReturnType<typeof postgres>, codigo: string) {
  const [resultado] = await sql<{ ranking: Record<string, unknown> }[]>`
    WITH evento AS (
      SELECT id, (statement_timestamp() AT TIME ZONE 'America/Sao_Paulo')::date AS dia
      FROM cadastro.eventos WHERE codigo = ${codigo}
    ), atletas AS (
      SELECT i.id, i.evento_id, i.numero_provisorio, s.nome, f.versao AS avatar_versao, cat.codigo AS categoria,
             cat.id::text AS categoria_id, cat.ordem, s.sexo_confirmado AS sexo,
             cat.id::text || ':' || s.sexo_confirmado AS grupo,
             CASE WHEN s.sexo_confirmado = 'Masculino' THEN 0 ELSE 1 END AS ordem_sexo
      FROM evento e JOIN cadastro.inscricoes i ON i.evento_id = e.id
      JOIN cadastro.skatistas s ON s.id = i.skatista_id
      LEFT JOIN cadastro.fotos_skatistas f ON f.skatista_id=s.id
      JOIN cadastro.categorias cat ON cat.id = i.categoria_base_id AND cat.evento_id = e.id
    ), grupos AS (
      SELECT DISTINCT grupo AS chave, categoria_id, categoria, sexo, ordem,
             categoria || ' ' || sexo AS rotulo, ordem_sexo
      FROM atletas
    ), concluidas AS (
      SELECT t.inscricao_id, t.volta, t.media
      FROM evento e JOIN operacao.tentativas t ON t.evento_id = e.id
      WHERE t.estado = 'concluida' AND t.dia_volta = e.dia
    ), medias AS (
      SELECT inscricao_id, max(media) FILTER (WHERE volta = 1) AS v1,
             max(media) FILTER (WHERE volta = 2) AS v2
      FROM concluidas GROUP BY inscricao_id
    ), classificados AS (
      SELECT a.*, m.v1, m.v2, greatest(m.v1, m.v2) AS melhor,
             rank() OVER (
               PARTITION BY a.grupo ORDER BY greatest(m.v1, m.v2) DESC NULLS LAST
             ) AS posicao
      FROM atletas a LEFT JOIN medias m ON m.inscricao_id = a.id
    ), filtro AS (
      SELECT filtro_categoria_id::text || ':' || filtro_sexo AS grupo,
             filtro_revisao::text AS revisao
      FROM operacao.controle_evento c JOIN evento e ON e.id = c.evento_id
    )
    SELECT jsonb_build_object(
      'categorias', coalesce((
        SELECT jsonb_agg(jsonb_build_object('codigo', c.codigo, 'ordem', c.ordem) ORDER BY c.ordem)
        FROM cadastro.categorias c JOIN evento e ON e.id = c.evento_id
      ), '[]'::jsonb),
      'grupos', coalesce((
        SELECT jsonb_agg(to_jsonb(g) - 'ordem_sexo' ORDER BY ordem, ordem_sexo) FROM grupos g
      ), '[]'::jsonb),
      'filtro', jsonb_build_object(
        'grupo', coalesce((SELECT g.chave FROM grupos g JOIN filtro f ON f.grupo = g.chave),
                          (SELECT chave FROM grupos ORDER BY ordem, ordem_sexo LIMIT 1)),
        'revisao', coalesce((SELECT revisao FROM filtro), '0')
      ),
      'inscricoes', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
          'id', id::text, 'nome', nome, 'numero_provisorio', numero_provisorio,
          'avatar_versao', avatar_versao, 'categoria', categoria, 'grupo', grupo, 'v1', v1::text, 'v2', v2::text,
          'nf', CASE WHEN v1 IS NOT NULL AND v2 IS NOT NULL THEN melhor::text END,
          'posicao', CASE WHEN melhor IS NOT NULL THEN posicao END
        ) ORDER BY ordem, ordem_sexo, melhor DESC NULLS LAST, numero_provisorio)
        FROM classificados
      ), '[]'::jsonb),
      'pista', (
        SELECT jsonb_build_object(
          'id', t.id::text, 'inscricao_id', a.id::text, 'volta', t.volta, 'estado', t.estado,
          'nome', a.nome, 'numero_provisorio', a.numero_provisorio,
          'categoria', a.categoria, 'grupo', a.grupo
        )
        FROM operacao.tentativas t JOIN atletas a
          ON a.id = t.inscricao_id AND a.evento_id = t.evento_id
        WHERE t.estado IN ('chamada', 'aberta')
      ),
      'dia', (SELECT dia FROM evento),
      'voltas_concluidas_hoje', coalesce((
        SELECT jsonb_agg(jsonb_build_object('inscricao_id', inscricao_id::text, 'volta', volta)
                         ORDER BY inscricao_id, volta)
        FROM concluidas
      ), '[]'::jsonb)
    ) AS ranking
  `;
  return resultado.ranking;
}
