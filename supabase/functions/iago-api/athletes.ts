import { parse } from "npm:csv-parse@5.6.0/sync";
import { readXlsx } from "./xlsx.ts";
import { session } from "./auth.ts";
import { body, bytes, type Context, date, digest, fail, string } from "./common.ts";
import { casefold } from "./casefold.ts";

const header = ["atleta", "escola", "data_nascimento", "ano_nascimento", "sexo_confirmado", "categoria_base_idade"];
const maxBytes = 2 * 1024 * 1024;
type Entry = {
  line: number; nome: string; escola: string; nascimento: string; sexo: string; categoria: string; key: string;
};
export async function validateRow(fields: unknown[], codigo: string, line: number, today: string): Promise<Entry> {
  if (fields.length !== 6 || fields.some((value) => value == null)) {
    fail(422, `Linha ${line}: preencha as seis colunas.`);
  }
  const [name, school, birth, year, sex, category] = fields;
  let nascimento: string;
  try {
    nascimento = date(typeof birth === "string" ? birth.trim() : birth);
    if (nascimento < "1900-01-01" || nascimento > today || String(year).trim() !== nascimento.slice(0, 4)) {
      throw new Error();
    }
  } catch { fail(422, `Linha ${line}: data ou ano inválido.`); }
  const [nome, escola, sexo, categoria] = [name, school, sex, category].map((value) => {
    if (typeof value !== "string" || value.includes("\0")) fail(422, `Linha ${line}: campos de texto inválidos.`);
    const trimmed = value.trim();
    if (!trimmed || [...trimmed].length > 200 || trimmed.startsWith("=")) {
      fail(422, `Linha ${line}: campos de texto inválidos.`);
    }
    return trimmed;
  });
  if (!["Masculino", "Feminino"].includes(sexo)) fail(422, `Linha ${line}: sexo confirmado inválido.`);
  const normalized = casefold(nome.normalize("NFKC")).replace(/[\p{White_Space}\u001c-\u001f]+/gu, " ").replace(/^ | $/g, "");
  const key = await digest("[" + [codigo, normalized, nascimento].map((text) => JSON.stringify(text)).join(", ") + "]");
  return { line, nome, escola, nascimento, sexo, categoria, key };
}
export async function parseFile(name: string, data: Uint8Array, codigo: string, today: string) {
  let rows: unknown[][];
  try {
    if (/\.csv$/i.test(name)) {
      rows = parse(new TextDecoder("utf-8", { fatal: true }).decode(data), {
        bom: true, delimiter: ";", relax_column_count: true, to: 1002,
      });
    } else if (/\.xlsx$/i.test(name)) rows = readXlsx(data);
    else fail(422, "Use um arquivo .xlsx ou .csv.");
  } catch (error) {
    if (error instanceof Error && "status" in error) throw error;
    fail(422, "Arquivo inválido. Use XLSX ou CSV UTF-8 separado por ponto e vírgula.");
  }
  if (JSON.stringify(rows[0]) !== JSON.stringify(header)) fail(422, "Cabeçalho inválido. Use o modelo de importação.");
  if (rows.length > 1001) fail(422, "Limite de 1000 linhas excedido.");
  const entries = [];
  for (const [i, fields] of rows.slice(1).entries()) {
    if (fields.every((value) => value == null || value === "")) continue;
    entries.push(await validateRow(fields, codigo, i + 2, today));
  }
  if (!entries.length) fail(422, "A planilha está vazia.");
  return entries;
}
async function save({ sql, request, codigo }: Context, entries: Entry[]) {
  return await sql.begin("read write", async (c) => {
    await session(c, request, { role: "master", lock: true });
    await c`SELECT pg_advisory_xact_lock(hashtext(${codigo}))`;
    const [event] = await c`SELECT id FROM cadastro.eventos WHERE codigo=${codigo}`;
    if (!event) fail(409, "Evento sem cadastro.");
    const categories = new Map((await c`SELECT id,codigo FROM cadastro.categorias
      WHERE evento_id=${event.id}`).map((r) => [r.codigo, r.id]));
    const existing = new Map((await c`SELECT i.chave_origem,s.escola,s.sexo_confirmado,i.categoria_base_id
      FROM cadastro.inscricoes i JOIN cadastro.skatistas s ON s.id=i.skatista_id
      WHERE i.evento_id=${event.id} AND i.chave_origem::text=ANY(${c.array(entries.map((e) => e.key), 25)})`
    ).map((r) => [r.chave_origem, [r.escola, r.sexo_confirmado, r.categoria_base_id]]));
    const newEntries = [];
    let duplicados = 0;
    for (const entry of entries) {
      const category = categories.get(entry.categoria);
      if (!category) fail(422, `Linha ${entry.line}: categoria-base indisponível no evento.`);
      const fields = [entry.escola, entry.sexo, category];
      const previous = existing.get(entry.key);
      if (previous) {
        if (fields.some((value, i) => value !== previous[i])) {
          fail(409, `Linha ${entry.line}: identidade já cadastrada com dados divergentes.`);
        }
        duplicados++;
      } else {
        existing.set(entry.key, fields);
        newEntries.push({ ...entry, category });
      }
    }
    const [{ numero }] = await c`SELECT coalesce(max(numero_provisorio),0) AS numero
      FROM cadastro.inscricoes WHERE evento_id=${event.id}`;
    // Batch insertion with explicit IDs avoids depending on a database driver's RETURNING order.
    if (newEntries.length) {
      const records = newEntries.map((entry, i) => ({ ...entry, id: crypto.randomUUID(), numero: numero + i + 1 }));
      await c`INSERT INTO cadastro.skatistas ${c(records.map((r) => ({
        id: r.id, nome: r.nome, escola: r.escola, data_nascimento: r.nascimento, sexo_confirmado: r.sexo,
      })), "id", "nome", "escola", "data_nascimento", "sexo_confirmado")}`;
      await c`INSERT INTO cadastro.inscricoes ${c(records.map((r) => ({
        evento_id: event.id, skatista_id: r.id, chave_origem: r.key, categoria_base_id: r.category, numero_provisorio: r.numero,
      })), "evento_id", "skatista_id", "chave_origem", "categoria_base_id", "numero_provisorio")}`;
    }
    return { incluidos: newEntries.length, duplicados };
  });
}
const today = () => new Date().toISOString().slice(0, 10);
export async function createAthlete(ctx: Context) {
  const data = await body(ctx.request);
  const birth = date(data.nascimento);
  const entry = await validateRow([
    string(data, "nome", 200), string(data, "escola", 200), birth, birth.slice(0, 4),
    string(data, "sexo", 20), string(data, "categoria", 200),
  ], ctx.codigo, 1, today());
  return await save(ctx, [entry]);
}
export async function importAthletes(ctx: Context) {
  await session(ctx.sql, ctx.request, { role: "master" });
  const name = ctx.url.searchParams.get("nome");
  if (name === null) fail(422, "Informe o nome do arquivo.");
  const data = await bytes(ctx.request, maxBytes, "Arquivo excede 2 MiB.");
  return await save(ctx, await parseFile(name, data, ctx.codigo, today()));
}
export async function athletes({ sql, request, codigo }: Context) {
  return await sql.begin("isolation level repeatable read read only", async (c) => {
    await session(c, request, { role: "master" });
    const inscricoes = await c`SELECT i.id,i.numero_provisorio,s.nome,s.escola,s.data_nascimento::text,
      s.ano_nascimento,s.sexo_confirmado,base.codigo AS categoria_base
      FROM cadastro.inscricoes i JOIN cadastro.eventos e ON e.id=i.evento_id
      JOIN cadastro.skatistas s ON s.id=i.skatista_id
      JOIN cadastro.categorias base ON base.id=i.categoria_base_id
      WHERE e.codigo=${codigo} ORDER BY i.numero_provisorio`;
    const rows = await c`SELECT c.codigo FROM cadastro.categorias c
      JOIN cadastro.eventos e ON e.id=c.evento_id WHERE e.codigo=${codigo} ORDER BY c.ordem`;
    return { inscricoes, categorias: rows.map((row) => row.codigo) };
  });
}
export async function notes({ sql, request, codigo, url }: Context) {
  const day = date(url.searchParams.get("dia"));
  await session(sql, request, { role: "master" });
  const notas = await sql`SELECT n.id,n.evento_id,n.tentativa_id,n.juiz_id,n.skatista_id,n.volta,n.nota::float8 AS nota,n.horario,n.dia_voto::text,n.dia_volta::text,n.estado FROM operacao.notas_por_dia n
    JOIN cadastro.eventos e ON e.id=n.evento_id WHERE e.codigo=${codigo} AND n.dia_voto=${day}
    ORDER BY n.horario,n.id`;
  return { notas };
}
