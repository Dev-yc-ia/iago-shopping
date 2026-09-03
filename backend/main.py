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

        @app.get("/", include_in_schema=False)
        def frontend_index() -> FileResponse:
            return FileResponse(FRONTEND_DIR / "index.html")

        @app.get("/{page_name}.html", include_in_schema=False)
        def frontend_page(page_name: str) -> FileResponse:
            allowed_pages = {
                "index",
                "catalogo",
                "produto",
                "carrinho",
                "checkout",
                "pedidos",
                "login",
                "admin",
                "recuperar-senha",
                "nova-senha",
            }
            if page_name not in allowed_pages:
                return FileResponse(FRONTEND_DIR / "index.html")
            return FileResponse(FRONTEND_DIR / f"{page_name}.html")

    return app


app = create_app()
