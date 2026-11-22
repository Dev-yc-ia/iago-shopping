import { session } from "./auth.ts";
import { body, type Context, fail, lockEvent, type Sql, string, uuid } from "./common.ts";

type Attempt = { id: string; evento_id: string; inscricao_id: string; volta: number; estado: string; dia_volta: string | null };
type Vote = { id: string; nota: string; horario: Date };
const receipt = (vote: Vote, id: string) => ({
  id: vote.id, tentativa_id: id, nota: vote.nota, horario: vote.horario.toISOString(),
});
async function current(c: Sql, event: string, lock = false) {
  const [attempt] = await c<Attempt[]>`SELECT * FROM operacao.tentativas
    WHERE evento_id=${event} AND estado IN ('chamada','aberta') ${lock ? c`FOR UPDATE` : c``}`;
  return attempt;
}
async function byId(c: Sql, event: string, id: string) {
  const [attempt] = await c<Attempt[]>`SELECT * FROM operacao.tentativas
    WHERE evento_id=${event} AND id=${id} FOR UPDATE`;
  if (!attempt) fail(404, "Tentativa não encontrada.");
  return attempt;
}
async function projection(c: Sql, attempt?: Attempt) {
  if (!attempt) return null;
  const { id, inscricao_id, volta, estado, evento_id } = attempt;
  const [athlete] = await c`SELECT s.nome,i.numero_provisorio,cat.codigo AS categoria,
    cat.id::text || ':' || s.sexo_confirmado AS grupo
    FROM cadastro.inscricoes i JOIN cadastro.skatistas s ON s.id=i.skatista_id
    JOIN cadastro.categorias cat ON cat.id=i.categoria_base_id
    WHERE i.id=${inscricao_id} AND i.evento_id=${evento_id}`;
  return { id, inscricao_id, volta, estado, ...athlete };
}
export async function prepare({ sql, request, codigo }: Context, open: boolean) {
  const data = await body(request);
  const id = uuid(data.inscricao_id);
  const { volta } = data;
  if (volta !== 1 && volta !== 2) fail(422, "Dados inválidos.");
  return await sql.begin("read write", async (c) => {
    const event = await lockEvent(c, codigo);
    const user = (await session(c, request, { role: "master", lock: true }))!;
    const [entry] = await c`SELECT id FROM cadastro.inscricoes WHERE evento_id=${event} AND id=${id}`;
    if (!entry) fail(404, "Inscrição não encontrada neste evento.");
    const [published] = await c`SELECT 1 FROM operacao.tentativas WHERE evento_id=${event}
      AND inscricao_id=${id} AND volta=${volta} AND estado='concluida'
      AND dia_volta=(clock_timestamp() AT TIME ZONE 'America/Sao_Paulo')::date`;
    if (published) fail(409, "Esta volta já tem resultado publicado.");
    const track = await current(c, event, true);
    if (track && (track.inscricao_id !== id || track.volta !== volta || track.estado !== "chamada" || !open)) {
      fail(409, "Já existe uma volta em pista. Conclua ou cancele antes de outra liberação.");
    }
    const judges = open ? await c`SELECT id FROM operacao.usuarios
      WHERE perfil='juiz' AND ativo ORDER BY id FOR SHARE` : [];
    if (open && !judges.length) fail(409, "Cadastre e ative pelo menos um juiz antes de liberar.");
    const [attempt] = track
      ? await c<Attempt[]>`UPDATE operacao.tentativas SET estado='aberta',aberta_em=now()
          WHERE id=${track.id} RETURNING *`
      : await c<Attempt[]>`INSERT INTO operacao.tentativas
          (evento_id,inscricao_id,volta,estado,criada_por,aberta_em)
          VALUES (${event},${id},${volta},${open ? "aberta" : "chamada"},${user.id},
            CASE WHEN ${open} THEN now() ELSE NULL END) RETURNING *`;
    if (judges.length) {
      await c`INSERT INTO operacao.bancas ${c(judges.map(({ id }) => ({
        evento_id: event, tentativa_id: attempt.id, juiz_id: id,
      })), "evento_id", "tentativa_id", "juiz_id")}`;
    }
    return { tentativa: await projection(c, attempt) };
  });
}
export async function cancel({ sql, request, codigo }: Context, id: string) {
  const reason = string(await body(request), "motivo", 500).trim();
  if ([...reason].length < 3) fail(400, "Informe o motivo do cancelamento (3 a 500 caracteres).");
  await sql.begin("read write", async (c) => {
    const event = await lockEvent(c, codigo);
    await session(c, request, { role: "master", lock: true });
    const attempt = await byId(c, event, id);
    if (!["chamada", "aberta"].includes(attempt.estado)) fail(409, "A tentativa já foi encerrada.");
    await c`UPDATE operacao.tentativas SET estado='cancelada',motivo_cancelamento=${reason},
      encerrada_em=now() WHERE id=${id}`;
  });
  return { mensagem: "Tentativa cancelada. Votos preservados internamente, sem resultado público." };
}
async function ownVote(c: Sql, event: string, id: string, user: string) {
  const [vote] = await c<Vote[]>`SELECT id,nota::text,horario FROM operacao.votos
    WHERE evento_id=${event} AND tentativa_id=${id} AND juiz_id=${user}`;
  return vote;
}
async function eligible(c: Sql, event: string, id: string, user: string) {
  return (await c`SELECT 1 FROM operacao.bancas
    WHERE evento_id=${event} AND tentativa_id=${id} AND juiz_id=${user}`).length > 0;
}
export function validateScore(value: string) {
  const cleaned = value.trim();
  if (!/^\d{1,3}([.,]\d{1,2})?$/.test(cleaned)) {
    fail(400, "Informe nota de 0 a 100 com até duas casas decimais.");
  }
  const n = Number(cleaned.replace(",", "."));
  if (n > 100) fail(400, "A nota deve estar entre 0 e 100.");
  return n.toFixed(2);
}
export async function vote({ sql, request, codigo }: Context, id: string) {
  const score = validateScore(string(await body(request), "nota", 64));
  return await sql.begin("read write", async (c) => {
    const event = await lockEvent(c, codigo);
    const user = (await session(c, request, { role: "juiz", lock: true }))!;
    const attempt = await byId(c, event, id);
    if (!await eligible(c, event, id, user.id)) fail(403, "Sua conta não integra a banca desta tentativa.");
    if (attempt.estado === "cancelada") fail(409, "Tentativa cancelada. Confira a volta atual.");
    const previous = await ownVote(c, event, id, user.id);
    if (previous) {
      if (previous.nota !== score) fail(409, "A nota já foi enviada e não pode ser substituída.");
      return { recibo: receipt(previous, id) };
    }
    if (attempt.estado !== "aberta") fail(409, "Esta tentativa não está recebendo notas.");
    const [saved] = await c<(Vote & { dia: string })[]>`INSERT INTO operacao.votos(evento_id,tentativa_id,juiz_id,nota,horario)
      VALUES (${event},${id},${user.id},${score},clock_timestamp())
      RETURNING id,nota::text,horario,(horario AT TIME ZONE 'America/Sao_Paulo')::date::text AS dia`;
    if (!attempt.dia_volta) {
      const [published] = await c`SELECT 1 FROM operacao.tentativas WHERE evento_id=${event}
        AND inscricao_id=${attempt.inscricao_id} AND volta=${attempt.volta}
        AND estado='concluida' AND dia_volta=${saved.dia}`;
      if (published) fail(409, "Esta volta já tem resultado publicado neste dia.");
      await c`UPDATE operacao.tentativas SET dia_volta=${saved.dia} WHERE id=${id}`;
    }
    await c`UPDATE operacao.tentativas SET estado='concluida',media=total.media,encerrada_em=now()
      FROM (SELECT count(*) AS n,round(avg(nota),2) AS media FROM operacao.votos
        WHERE evento_id=${event} AND tentativa_id=${id}) total
      WHERE id=${id} AND total.n=(SELECT count(*) FROM operacao.bancas
        WHERE evento_id=${event} AND tentativa_id=${id})`;
    return { recibo: receipt(saved, id) };
  });
}
export async function state({ sql, request, codigo }: Context) {
  return await sql.begin("isolation level repeatable read read only", async (c) => {
    const user = (await session(c, request))!;
    const [event] = await c`SELECT id FROM cadastro.eventos WHERE codigo=${codigo}`;
    const attempt = event ? await current(c, event.id) : undefined;
    const tentativa = await projection(c, attempt);
    if (!attempt) return { tentativa };
    const { id, evento_id } = attempt;
    if (user.perfil === "master") {
      const judges = await c`SELECT u.id,u.nome,u.login,v.id AS voto_id FROM operacao.bancas b
        JOIN operacao.usuarios u ON u.id=b.juiz_id
        LEFT JOIN operacao.votos v ON v.evento_id=b.evento_id AND v.tentativa_id=b.tentativa_id AND v.juiz_id=b.juiz_id
        WHERE b.evento_id=${evento_id} AND b.tentativa_id=${id} ORDER BY u.nome,u.id`;
      const pendentes = judges.filter((r) => !r.voto_id).map(({ id, nome, login }) => ({ id, nome, login }));
      return { tentativa, total: judges.length, recebidos: judges.length - pendentes.length, pendentes };
    }
    const elegivel = await eligible(c, evento_id, id, user.id);
    const sent = await ownVote(c, evento_id, id, user.id);
    return { tentativa, elegivel, enviado: !!sent, recibo: sent ? receipt(sent, id) : null };
  });
}
export async function filter({ sql, request, codigo }: Context) {
  const group = string(await body(request), "grupo", 100, 1);
  return await sql.begin("read write", async (c) => {
    const event = await lockEvent(c, codigo);
    await session(c, request, { role: "master", lock: true });
    const [choice] = await c`SELECT cat.id,s.sexo_confirmado AS sexo
      FROM cadastro.inscricoes i JOIN cadastro.skatistas s ON s.id=i.skatista_id
      JOIN cadastro.categorias cat ON cat.evento_id=i.evento_id AND cat.id=i.categoria_base_id
      WHERE i.evento_id=${event} AND cat.id::text || ':' || s.sexo_confirmado=${group} LIMIT 1`;
    if (!choice) fail(422, "Grupo não encontrado neste evento.");
    const [filtro] = await c`UPDATE operacao.controle_evento SET filtro_categoria_id=${choice.id},
      filtro_sexo=${choice.sexo},filtro_revisao=filtro_revisao+1 WHERE evento_id=${event}
      RETURNING filtro_categoria_id::text || ':' || filtro_sexo AS grupo,filtro_revisao::text AS revisao`;
    return { filtro, mensagem: "Filtro publicado." };
  });
}
