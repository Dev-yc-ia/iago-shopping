from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"
MIGRATION = ROOT / "sql" / "migrations" / "20260910_022_web11_cadastro_parceiro_aceite_termos.sql"
PDF = FRONTEND / "assets" / "docs" / "termos" / "Termos_Condicoes_Vendedores_IAGO_Shopping_V1.0.pdf"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web11_pdf_and_terms_configuration_are_versioned():
    terms = read(FRONTEND / "config" / "sellerTerms.js")
    page = read(FRONTEND / "cadastro-parceiro" / "index.html")

    assert PDF.exists()
    assert PDF.stat().st_size > 0
    assert 'id: "termos-vendedores"' in terms
    assert 'version: "1.0"' in terms
    assert 'effectiveDate: "2026-09-10"' in terms
    assert "/assets/docs/termos/Termos_Condicoes_Vendedores_IAGO_Shopping_V1.0.pdf" in terms
    assert "47AD1E9869F29747F49AD0399C28784EC25030B8BF196FA8B5B3900467672BB7" in terms
    assert "Declaro que li e aceito os Termos e Condições de Uso para Vendedores do IAGO Shopping," in terms
    assert 'data-seller-terms-read' in page
    assert 'data-seller-terms-download' in page
    assert 'data-seller-terms-checkbox' in page
    assert "Vigência: <span data-seller-terms-effective>10/09/2026</span>" in page


def test_web11_frontend_adds_partner_route_auth_and_google_return():
    core = read(FRONTEND / "core" / "app.js")
    login = read(FRONTEND / "login" / "index.html")
    home = read(FRONTEND / "index.html")
    page = read(FRONTEND / "cadastro-parceiro" / "index.html")
    partner = read(FRONTEND / "features" / "partnerSignup.js")
    auth = read(FRONTEND / "features" / "auth.js")
    main = read(ROOT / "backend" / "main.py")

    for fragment in [
        'data-page="partner-signup"',
        "initPartnerSignupPage",
        'page === "partner-signup"',
        "Quero vender no IAGO",
        "/cadastro-parceiro/",
        "signUpParceiro",
        "signInWithGoogle(\"/cadastro-parceiro/\")",
        "shopping_parceiro_solicitar_cadastro",
        "Entre com e-mail/senha ou Google antes de enviar a solicitação.",
        "Para enviar a solicitação, aceite os Termos e Condições para Vendedores.",
    ]:
        assert fragment in core + login + home + page + partner + auth + main


def test_web11_sql_persists_acceptance_and_pending_application_without_auto_role():
    migration = read(MIGRATION)

    for fragment in [
        "create table if not exists public.shopping_termos_aceites",
        "user_id uuid not null references auth.users(id) on delete cascade",
        "termo_id text not null",
        "versao_termo text not null",
        "documento_hash text not null",
        "tipo_pessoa public.shopping_tipo_pessoa_parceiro not null",
        "aceito_em timestamptz not null default now()",
        "ip_aceite inet",
        "user_agent text",
        "constraint shopping_termos_aceites_unico unique (user_id, termo_id, versao_termo)",
        "on conflict on constraint shopping_termos_aceites_unico do update",
        "create table if not exists public.shopping_solicitacoes_parceiro",
        "status public.shopping_status_solicitacao_parceiro not null default 'pendente'",
        "and ss.status = 'pendente'::public.shopping_status_solicitacao_parceiro",
        "p_aceite boolean default false",
        "v_actor uuid := auth.uid()",
        "'pendente'::public.shopping_status_solicitacao_parceiro",
        "parceiro.solicitacao_cadastro",
    ]:
        assert fragment in migration

    solicitar = migration.split("create or replace function public.shopping_parceiro_solicitar_cadastro", 1)[1]
    solicitar = solicitar.split("drop function if exists public.shopping_admin_listar_solicitacoes_parceiro", 1)[0]
    assert "set papel = 'parceiro'" not in solicitar
    assert "set status_ativacao = 'ativo'" not in solicitar
    assert "select to_jsonb(ss), ss" not in migration
    assert "select to_jsonb(sp), sp" not in migration
    assert "on conflict (user_id, termo_id, versao_termo)" not in migration
    assert "where user_id = v_actor" not in solicitar
    assert "and status = 'pendente'::public.shopping_status_solicitacao_parceiro" not in solicitar
    assert "order by solicitado_em desc" not in solicitar
    assert "where id = v_existing_pendente" not in solicitar
    assert "where ss.user_id = v_actor" in solicitar
    assert "and ss.status = 'pendente'::public.shopping_status_solicitacao_parceiro" in solicitar
    assert "order by ss.solicitado_em desc" in solicitar
    assert "v_antes_solicitacao := to_jsonb(v_solicitacao);" in migration
    assert "v_antes_perfil := to_jsonb(v_perfil);" in migration


def test_web11_master_admin_decides_and_web10_partner_dropdown_reuses_active_profile():
    migration = read(MIGRATION)
    admin_html = read(FRONTEND / "admin" / "index.html")
    admin_js = read(FRONTEND / "features" / "admin.js")
    web10 = read(ROOT / "sql" / "migrations" / "20260909_018_web10_parceiros_entrega_recebimento_repasse.sql")

    for fragment in [
        "shopping_admin_listar_solicitacoes_parceiro",
        "Somente master ativo pode listar solicitacoes de parceiros.",
        "shopping_admin_decidir_solicitacao_parceiro",
        "Somente master ativo pode aprovar ou recusar parceiros.",
        "Motivo da recusa e obrigatorio.",
        "set papel = 'parceiro'::public.shopping_papel",
        "status_ativacao = 'ativo'::public.shopping_status_ativacao",
        "parceiro.solicitacao_aprovada",
        "parceiro.solicitacao_recusada",
        "data-partner-applications",
        "Solicitações de parceiros",
        "listPartnerApplications",
        "decidePartnerApplication",
        "Aprovar",
        "Recusar",
    ]:
        assert fragment in migration + admin_html + admin_js

    decidir = migration.split("create or replace function public.shopping_admin_decidir_solicitacao_parceiro", 1)[1]
    decidir = decidir.split("revoke all on function public.shopping_parceiro_solicitar_cadastro", 1)[0]
    assert "where id = v_solicitacao.id" not in decidir
    assert "where user_id = v_solicitacao.user_id" not in decidir
    assert "where ss.id = v_solicitacao.id" in decidir
    assert "where sp.user_id = v_solicitacao.user_id" in decidir

    assert "shopping_admin_listar_parceiros_ativos" in web10
    assert "sp.papel = 'parceiro'::public.shopping_papel" in web10
    assert "sp.status_ativacao = 'ativo'::public.shopping_status_ativacao" in web10


def test_web11_rls_blocks_third_party_reads_and_direct_writes():
    migration = read(MIGRATION)

    for fragment in [
        "alter table public.shopping_termos_aceites enable row level security",
        "alter table public.shopping_solicitacoes_parceiro enable row level security",
        "user_id = auth.uid()",
        "or public.shopping_is_master(auth.uid())",
        "revoke all on public.shopping_termos_aceites from anon, authenticated",
        "revoke all on public.shopping_solicitacoes_parceiro from anon, authenticated",
        "grant select on public.shopping_termos_aceites to authenticated",
        "grant select on public.shopping_solicitacoes_parceiro to authenticated",
        "grant execute on function public.shopping_parceiro_solicitar_cadastro",
        "grant execute on function public.shopping_admin_decidir_solicitacao_parceiro",
    ]:
        assert fragment in migration

    assert "grant insert" not in migration.lower()
    assert "grant update" not in migration.lower()
