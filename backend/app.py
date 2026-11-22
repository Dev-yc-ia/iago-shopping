"""Frontend e API na mesma origem, restritos à máquina local nesta etapa."""

import psycopg
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.trustedhost import TrustedHostMiddleware

from backend.config.paths import FRONTEND_DIR
from backend.config.settings import get_settings
from backend.db import read_connection
from backend.routers.operacao import router as operacao_router
from backend.routers.skatistas import router
from backend.security import sessao

app = FastAPI(
    title="Iago System local", docs_url=None, redoc_url=None, openapi_url=None
)
app.add_middleware(
    TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost", "[::1]"]
)


@app.middleware("http")
async def proteger_acesso_local(request: Request, call_next):
    """Loopback e no-store: não expor menores na rede nem manter respostas em cache."""
    if not request.client or request.client.host not in {"127.0.0.1", "::1"}:
        return JSONResponse(
            {"detail": "Acesso permitido somente nesta máquina."}, status_code=403
        )
    # Recusa leitura cross-site; não habilitamos CORS nem proxy nesta etapa.
    origin = request.headers.get("origin")
    if request.url.path.startswith("/api/") and (
        request.headers.get("sec-fetch-site") == "cross-site"
        or (origin and origin != str(request.base_url).rstrip("/"))
        or (
            request.method not in {"GET", "HEAD", "OPTIONS"}
            and origin != str(request.base_url).rstrip("/")
        )
    ):
        return JSONResponse({"detail": "Origem não permitida."}, status_code=403)
    # Protege também /index.html e variantes das pastas, antes da montagem estática.
    caminho = request.url.path.rstrip("/")
    protegida = (
        caminho == "/skatistas"
        or caminho.startswith(("/skatistas/", "/admin/", "/alterar-senha/"))
        or caminho == "/admin"
        or caminho == "/alterar-senha"
    )
    if protegida:
        try:
            with read_connection(
                app.dependency_overrides.get(get_settings, get_settings)()
            ) as c:
                usuario = sessao(c, request, permitir_troca=True)
            if usuario["trocar_senha"] and not caminho.startswith("/alterar-senha"):
                return RedirectResponse(
                    "/alterar-senha/",
                    status_code=303,
                    headers={"Cache-Control": "no-store"},
                )
            if (
                not caminho.startswith("/alterar-senha")
                and usuario["perfil"] != "master"
            ):
                return HTMLResponse(
                    '<html lang="pt-BR"><p>Acesso exclusivo do master. <a href="/">Voltar ao ranking</a></p></html>',
                    status_code=403,
                    headers={"Cache-Control": "no-store"},
                )
        except HTTPException:
            return RedirectResponse(
                "/login/", status_code=303, headers={"Cache-Control": "no-store"}
            )
        except psycopg.Error:
            return JSONResponse(
                {"detail": "Banco local indisponível."}, status_code=503
            )
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    return response


@app.exception_handler(psycopg.Error)
async def falha_banco(request, error):
    return JSONResponse(
        {"detail": "Banco local indisponível. Tente novamente."},
        status_code=503,
        headers={"Cache-Control": "no-store"},
    )


@app.exception_handler(RequestValidationError)
async def entrada_invalida(request, error):
    # O erro padrão do validador incluiria o valor recebido, inclusive senhas.
    return JSONResponse(
        {"detail": "Dados inválidos. Confira os campos."},
        status_code=422,
        headers={"Cache-Control": "no-store"},
    )


app.include_router(operacao_router)
app.include_router(router)
# Montar por último impede que o frontend capture URLs da API.
app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")
