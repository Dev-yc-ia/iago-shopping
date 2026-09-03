from fastapi import APIRouter

from backend.config.settings import ENV_FILE, Settings, get_settings
from backend.schemas.config import PublicConfigResponse


router = APIRouter(tags=["config"])


def get_public_settings() -> Settings:
    settings = get_settings()
    if settings.supabase_configured or not ENV_FILE.exists():
        return settings

    get_settings.cache_clear()
    return get_settings()


@router.get("/api/config/public", response_model=PublicConfigResponse)
def public_config() -> PublicConfigResponse:
    settings = get_public_settings()
    return PublicConfigResponse(
        supabase_url=settings.supabase_url,
        supabase_anon_key=settings.supabase_anon_key,
        supabase_configured=settings.supabase_configured,
    )
