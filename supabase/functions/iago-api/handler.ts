import postgres from "npm:postgres@3.4.7";
import { ranking } from "./ranking.ts";
import * as auth from "./auth.ts";
import * as competition from "./competition.ts";
import * as athletes from "./athletes.ts";
import { type Context, errorCode, HttpError, uuid } from "./common.ts";

const dsn = Deno.env.get("IAGO_RUNTIME_DATABASE_URL");
const codigo = Deno.env.get("EVENTO_CODIGO") ?? "acsn-inicial";
const origins = new Set([
  "https://ia-go.api.br", "https://dev-yc-ia.github.io",
  ...(Deno.env.get("IAGO_TEST_ORIGINS") ?? "").split(",").map((origin) => origin.trim()).filter(Boolean),
]);
let sql: Context["sql"] | undefined;
function database() {
  if (!dsn) throw new Error("secret_ausente");
  return sql ??= postgres(dsn, {
    prepare: false, max: 2, ssl: "require", connect_timeout: 5, idle_timeout: 15,
  });
}
type Route = {
  method: string;
  path: string | RegExp;
  handler: (ctx: Context, id: string) => Promise<unknown>;
  status?: number;
};
const routes: Route[] = [
  { method: "GET", path: "/ranking", handler: (ctx) => ranking(ctx.sql, ctx.codigo) },
  { method: "GET", path: "/sessao", handler: auth.getSession },
  { method: "POST", path: "/auth/login", handler: auth.login },
  { method: "POST", path: "/auth/senha", handler: auth.changePassword },
  { method: "POST", path: "/auth/logout", handler: auth.logout },
  { method: "GET", path: "/usuarios", handler: auth.judges },
  { method: "POST", path: "/usuarios", handler: auth.createJudge, status: 201 },
  { method: "PATCH", path: /^\/usuarios\/([^/]+)$/, handler: auth.updateJudge },
  { method: "GET", path: "/competicao/estado", handler: competition.state },
  { method: "POST", path: "/competicao/chamar", handler: (ctx) => competition.prepare(ctx, false) },
  { method: "POST", path: "/competicao/abrir", handler: (ctx) => competition.prepare(ctx, true) },
  { method: "POST", path: /^\/competicao\/([^/]+)\/cancelar$/, handler: competition.cancel },
  { method: "POST", path: /^\/competicao\/([^/]+)\/votos$/, handler: competition.vote },
  { method: "POST", path: "/competicao/filtro", handler: competition.filter },
  { method: "GET", path: "/skatistas", handler: athletes.athletes },
  { method: "POST", path: "/skatistas", handler: athletes.createAthlete },
  { method: "POST", path: "/skatistas/importar", handler: athletes.importAthletes },
  { method: "GET", path: "/notas", handler: athletes.notes },
];

export async function handle(request: Request, connect: () => Context["sql"] = database) {
  const origin = request.headers.get("origin");
  const headers = new Headers({ "Cache-Control": "no-store", Vary: "Origin" });
  const json = (content: unknown, status = 200) => Response.json(content, { status, headers });
  if (origin && !origins.has(origin)) return json({ detail: "Origem não permitida." }, 403);
  if (origin) headers.set("Access-Control-Allow-Origin", origin);
  const url = new URL(request.url);
  const path = /^(?:\/functions\/v1)?\/iago-api(\/.*)$/.exec(url.pathname)?.[1] ?? "";
  const candidates = routes.filter(({ path: pattern }) => typeof pattern === "string" ? pattern === path : pattern.test(path));
  if (!candidates.length) return json({ detail: "Rota não encontrada." }, 404);
  const methods = [...candidates.map((route) => route.method), "OPTIONS"].join(", ");
  if (request.method === "OPTIONS") {
    headers.set("Access-Control-Allow-Methods", methods);
    headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-CSRF-Token");
    headers.set("Access-Control-Max-Age", "600");
    return new Response(null, { status: 204, headers });
  }
  const route = candidates.find(({ method }) => request.method === method);
  if (!route) {
    headers.set("Allow", methods);
    return json({ detail: "Método não permitido." }, 405);
  }
  const label = path === "/ranking" ? "ranking:" : "iago-api:";
  let stage = dsn ? "driver_inicializacao" : "secret_ausente";
  try {
    const sql = connect();
    stage = "consulta";
    const id = route.path instanceof RegExp ? uuid(route.path.exec(path)?.[1]) : "";
    return json(await route.handler({ sql, codigo, request, url }, id), route.status);
  } catch (error) {
    if (error instanceof HttpError) return json({ detail: error.message }, error.status);
    const code = errorCode(error);
    if (code === "23505" && (error as { constraint_name?: string }).constraint_name === "um_resultado_por_volta_dia") {
      return json({ detail: "Esta volta já tem resultado publicado neste dia." }, 409);
    }
    if (stage === "consulta") {
      stage = /^(08|28)|^(CONNECT|CONNECTION|ENOTFOUND|EAI_|ECONN|ETIMEDOUT|ERR_SSL|CERT_)/.test(code)
        ? "conexao" : /^[0-9A-Z]{5}$/.test(code) ? "sql" : "runtime";
    }
    console.error(label, { etapa: stage, codigo: code });
    const unavailable = path === "/ranking" || stage !== "runtime";
    return json({ detail: unavailable ? "Banco indisponível." : "Não foi possível concluir." }, unavailable ? 503 : 500);
  }
}
