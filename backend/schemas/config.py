from pydantic import BaseModel


class PublicConfigResponse(BaseModel):
    supabase_url: str
    supabase_anon_key: str
    supabase_configured: bool
