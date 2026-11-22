"""Caminhos absolutos: somente FRONTEND_DIR pode ser publicado."""

from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parents[2]
FRONTEND_DIR = PROJECT_DIR / "frontend"
ENV_FILE = PROJECT_DIR / ".env"
PRIVATE_CSV = PROJECT_DIR / "dados_privados" / "skatistas_cadastro_inicial.csv"
MIGRATIONS_DIR = PROJECT_DIR / "supabase" / "migrations"
