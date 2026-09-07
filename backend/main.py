from pathlib import Path
import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from backend.config.settings import get_settings, safe_settings_diagnostics
from backend.routers.config import router as config_router
from backend.routers.health import router as health_router
from backend.routers.payments import router as payments_router


BASE_DIR = Path(__file__).resolve().parents[1]
FRONTEND_DIR = BASE_DIR / "frontend"
logger = logging.getLogger("iago.shopping")


def create_app() -> FastAPI:
    settings = get_settings()

    app = FastAPI(
        title=settings.app_name,
        version=settings.app_version,
        description=(
            "Fase 2 local do IAGO Shopping: health, configuração pública "
            "e servidor opcional do frontend estático."
        ),
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=False,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["*"],
    )

    app.include_router(health_router)
    app.include_router(config_router)
    app.include_router(payments_router)
    logger.info("IAGO Shopping config: %s", safe_settings_diagnostics(settings))

    if FRONTEND_DIR.exists():
        for folder in ("assets", "config", "core", "features", "ui", "utils", "css", "js"):
            static_dir = FRONTEND_DIR / folder
            if static_dir.exists():
                app.mount(f"/{folder}", StaticFiles(directory=static_dir), name=f"frontend-{folder}")

        frontend_routes = {
            "catalogo": FRONTEND_DIR / "catalogo" / "index.html",
            "produto": FRONTEND_DIR / "produto" / "index.html",
            "carrinho": FRONTEND_DIR / "carrinho" / "index.html",
            "checkout": FRONTEND_DIR / "checkout" / "index.html",
            "pedidos": FRONTEND_DIR / "pedidos" / "index.html",
            "login": FRONTEND_DIR / "login" / "index.html",
            "admin": FRONTEND_DIR / "admin" / "index.html",
            "recuperar-senha": FRONTEND_DIR / "recuperar-senha" / "index.html",
            "nova-senha": FRONTEND_DIR / "nova-senha" / "index.html",
        }

        @app.get("/", include_in_schema=False)
        def frontend_index() -> FileResponse:
            return FileResponse(FRONTEND_DIR / "index.html")

        @app.get("/{page_name}/", include_in_schema=False)
        def frontend_clean_page(page_name: str) -> FileResponse:
            return FileResponse(frontend_routes.get(page_name, FRONTEND_DIR / "index.html"))

    return app


app = create_app()
