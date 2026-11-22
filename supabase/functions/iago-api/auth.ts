import { argon2id, argon2Verify } from "npm:hash-wasm@4.12.0";
import { body, type Context, digest, errorCode, fail, lockEvent, type Sql, string } from "./common.ts";

const dummy = "$argon2id$v=19$m=19456,t=2,p=1$gEGq4wsq+dPz5LNC09v0PQ$KB5MeE9h19E0tjCsnW4zP0ZYrtrGKjR5vtdtnBJuWtw";
const token = () => Array.from(crypto.getRandomValues(new Uint8Array(32)),
  (b) => b.toString(16).padStart(2, "0")).join("");
const passwordHash = (password: string) => argon2id({
  password, salt: crypto.getRandomValues(new Uint8Array(16)),
  parallelism: 1, iterations: 2, memorySize: 19456, hashLength: 32, outputType: "encoded",
});
async function verify(hash: string, password: string) {
  try { return await argon2Verify({ hash, password }); }
  catch { return false; }
}
function passwordPolicy(password: string) {
  if ([...password].length < 6) fail(400, "Use ao menos 6 caracteres.");
}
async function newSession(c: Sql, id: string) {
  const value = token();
  const hash = await digest(value);
  const csrf = token();
  const hours = Number(Deno.env.get("IAGO_SESSION_HOURS") ?? "8");
  if (!Number.isInteger(hours) || hours < 1 || hours > 24 * 30) {
    throw new Error("IAGO_SESSION_HOURS inválido");
  }
  await c`INSERT INTO operacao.sessoes(token_hash,usuario_id,csrf_token,expira_em)
    VALUES (${hash},${id},${csrf},now()+make_interval(hours => ${hours}))`;
  return value;
}
export async function session(c: Sql, request: Request, options: {
  role?: "master" | "juiz"; allowChange?: boolean; lock?: boolean; optional?: boolean;
} = {}) {
  const bearer = /^Bearer ([0-9a-f]{64})$/i.exec(request.headers.get("authorization") ?? "");
  const [user] = bearer ? await c`
    SELECT u.id,u.nome,u.login,u.perfil,u.trocar_senha,s.token_hash,s.csrf_token
    FROM operacao.sessoes s JOIN operacao.usuarios u ON u.id=s.usuario_id
    WHERE s.token_hash=${await digest(bearer[1])} AND s.expira_em>now() AND u.ativo
    ${options.lock ? c`FOR SHARE OF u` : c``}
  ` : [];
  if (!user) {
    if (options.optional) return null;
    fail(401, "Entre para continuar.");
  }
  if (user.trocar_senha && !options.allowChange) fail(403, "Altere a senha antes de continuar.");
  if (options.role && user.perfil !== options.role) fail(403, "Ação não permitida para esta conta.");
  if (request.method !== "GET" && request.headers.get("x-csrf-token") !== user.csrf_token) {
    fail(403, "Confirmação de segurança inválida. Atualize a página.");
  }
  return user;
}
export async function getSession({ sql, request }: Context) {
  const user = await session(sql, request, { optional: true, allowChange: true });
  if (!user) return { autenticado: false };
  const { id, nome, login, perfil, trocar_senha, csrf_token } = user;
  return { autenticado: true, id, nome, login, perfil, trocar_senha, csrf_token };
}
export async function login({ sql, request }: Context) {
  const data = await body(request);
  const name = string(data, "login", 60).trim().toLowerCase();
  const password = string(data, "senha");
  // Limite por conta, independente de cabeçalhos de IP enviados pelo cliente.
  const key = await digest("edge-login|" + name);
  const value = await sql.begin("read write", async (c) => {
    await c`SELECT pg_advisory_xact_lock(hashtext(${key}))`;
    await c`DELETE FROM operacao.login_falhas WHERE horario<now()-interval '15 minutes'`;
    const [failures] = await c`SELECT count(*)::int AS n FROM operacao.login_falhas WHERE chave=${key}`;
    if (failures.n >= 5) fail(429, "Não foi possível entrar. Aguarde e tente novamente.");
    const [user] = await c`SELECT id,senha_hash,ativo FROM operacao.usuarios WHERE login=${name} FOR SHARE`;
    const valid = await verify(user?.senha_hash ?? dummy, password);
    if (!user?.ativo || !valid) {
      await c`INSERT INTO operacao.login_falhas(chave) VALUES (${key})`;
      return null;
    }
    await c`DELETE FROM operacao.login_falhas WHERE chave=${key}`;
    return await newSession(c, user.id);
  });
  if (!value) fail(401, "Login ou senha inválidos.");
  return { mensagem: "Acesso confirmado.", token: value };
}
export async function changePassword({ sql, request }: Context) {
  const data = await body(request);
  const current = string(data, "atual");
  const next = string(data, "nova");
  passwordPolicy(next);
  if (next !== string(data, "confirmacao") || current === next) {
    fail(400, "Confirme uma nova senha diferente da atual.");
  }
  const value = await sql.begin("read write", async (c) => {
    const user = (await session(c, request, { allowChange: true }))!;
    const [target] = await c`SELECT senha_hash FROM operacao.usuarios WHERE id=${user.id} FOR UPDATE`;
    await session(c, request, { allowChange: true });
    if (!await verify(target.senha_hash, current)) fail(400, "Não foi possível alterar a senha. Confira os campos.");
    const hash = await passwordHash(next);
    await c`UPDATE operacao.usuarios SET senha_hash=${hash},trocar_senha=false WHERE id=${user.id}`;
    await c`DELETE FROM operacao.sessoes WHERE usuario_id=${user.id}`;
    return await newSession(c, user.id);
  });
  return { mensagem: "Senha alterada. Outras sessões foram revogadas.", token: value };
}
export async function logout({ sql, request }: Context) {
  await sql.begin("read write", async (c) => {
    const user = (await session(c, request, { allowChange: true }))!;
    await c`DELETE FROM operacao.sessoes WHERE token_hash=${user.token_hash}`;
  });
  return { mensagem: "Sessão encerrada." };
}
export async function judges({ sql, request }: Context) {
  await session(sql, request, { role: "master" });
  return { usuarios: await sql`SELECT id,nome,login,ativo,trocar_senha FROM operacao.usuarios
    WHERE perfil='juiz' ORDER BY nome,id` };
}
export async function createJudge({ sql, request, codigo }: Context) {
  const data = await body(request);
  const name = string(data, "nome", 120, 1).trim();
  const login = string(data, "login", 60).trim().toLowerCase();
  const password = string(data, "senha");
  passwordPolicy(password);
  if (!name || !/^[a-z0-9_.-]{3,60}$/.test(login)) {
    fail(400, "Informe nome e login válido com 3 a 60 letras, números, ponto, hífen ou sublinhado.");
  }
  try {
    await sql.begin("read write", async (c) => {
      await lockEvent(c, codigo);
      await session(c, request, { role: "master", lock: true });
      const hash = await passwordHash(password);
      await c`INSERT INTO operacao.usuarios(nome,login,senha_hash,perfil) VALUES (${name},${login},${hash},'juiz')`;
    });
  } catch (error) {
    if (errorCode(error) === "23505") fail(409, "Login indisponível.");
    throw error;
  }
  return { mensagem: "Juiz cadastrado. A senha deve ser alterada no primeiro acesso." };
}
export async function updateJudge({ sql, request, codigo }: Context, id: string) {
  const { ativo } = await body(request);
  if (typeof ativo !== "boolean") fail(422, "Dados inválidos.");
  await sql.begin("read write", async (c) => {
    await lockEvent(c, codigo);
    await session(c, request, { role: "master", lock: true });
    const [user] = await c`UPDATE operacao.usuarios SET ativo=${ativo}
      WHERE id=${id} AND perfil='juiz' RETURNING id`;
    if (!user) fail(404, "Juiz não encontrado.");
    if (!ativo) await c`DELETE FROM operacao.sessoes WHERE usuario_id=${id}`;
  });
  return { mensagem: "Status atualizado. A banca já aberta permanece congelada." };
}
