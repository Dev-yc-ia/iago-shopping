from functools import lru_cache
from pathlib import Path
from typing import List

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


BASE_DIR = Path(__file__).resolve().parents[2]
ENV_FILE = BASE_DIR / ".env"


class Settings(BaseSettings):
    app_name: str = "IAGO Shopping"
    app_version: str = "0.0.0-fase2"
    environment: str = "local"
    cors_origins: List[str] = Field(default_factory=lambda: ["*"])
    supabase_url: str = ""
    supabase_anon_key: str = ""
    supabase_service_role_key: str = ""
    payment_provider: str = "mock"
    mock_payment_scenario: str = "sempre_aprovar"
    mock_payment_delay_ms: int = 3500
    mock_payment_timeout_ms: int = 9000
    mock_payment_expiration_ms: int = 300000
    mercado_pago_access_token: str = ""
    mercado_pago_public_key: str = ""
    mercado_pago_webhook_secret: str = ""
    mercado_pago_notification_url: str = ""
    mercado_pago_payment_expiration_minutes: int = 30
    mercado_pago_poll_interval_ms: int = 3000

    @property
    def supabase_configured(self) -> bool:
        if not (self.supabase_url and self.supabase_anon_key):
            return False
        return "seu-projeto" not in self.supabase_url and "sua-anon-key" not in self.supabase_anon_key

    model_config = SettingsConfigDict(
        env_file=ENV_FILE,
        env_file_encoding="utf-8",
        extra="ignore",
    )


@lru_cache
def get_settings() -> Settings:
    return Settings()


def safe_settings_diagnostics(settings: Settings | None = None) -> dict[str, str]:
    current = settings or get_settings()

    def status(value: str) -> str:
        return "OK" if str(value or "").strip() else "VAZIO"

    payment_provider = current.payment_provider.strip().lower()

    return {
        "ENV_FILE": str(ENV_FILE.resolve()),
        "ENV_EXISTS": "OK" if ENV_FILE.exists() else "NAO_ENCONTRADO",
        "PAYMENT_PROVIDER": current.payment_provider,
        "MERCADO_PAGO_MODE": "PRODUCAO" if payment_provider == "mercado_pago_prod" else "SANDBOX",
        "MERCADO_PAGO_ACCESS_TOKEN": status(current.mercado_pago_access_token),
        "MERCADO_PAGO_PUBLIC_KEY": status(current.mercado_pago_public_key),
        "SUPABASE_URL": status(current.supabase_url),
        "SUPABASE_SERVICE_ROLE_KEY": status(current.supabase_service_role_key),
    }
