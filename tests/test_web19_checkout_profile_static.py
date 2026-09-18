from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend"
MIGRATION = ROOT / "sql" / "migrations" / "20260918_024_web19_cadastro_obrigatorio_checkout_cep.sql"


def read(path):
    return path.read_text(encoding="utf-8")


def test_web19_cart_blocks_checkout_before_order_rpc_when_profile_is_incomplete():
    cart = read(FRONTEND / "features" / "cart.js")
    validator = read(FRONTEND / "utils" / "checkoutProfile.js")

    validation_index = cart.index("validateCheckoutProfile(")
    order_rpc_index = cart.index('supabase.rpc("shopping_pedido_finalizar_carrinho")')

    assert validation_index < order_rpc_index
    assert 'supabase.rpc("shopping_perfil_atual")' in cart
    assert 'supabase.rpc("shopping_endereco_padrao_atual")' in cart
    assert 'window.location.href = "/dados-pessoais/?aviso=checkout&redirect=/carrinho/"' in cart
    assert "recordEvent(\"checkout_profile_required\"" in cart

    for fragment in [
        "nomeCompleto",
        "email",
        "telefone",
        "nomeDestinatario",
        "cep",
        "logradouro",
        "numero",
        "bairro",
        "cidade",
        "uf",
        "digits.length >= 10",
        "onlyDigits(value).length === 8",
        "^[A-Z]{2}$",
    ]:
        assert fragment in validator


def test_web19_profile_page_shows_checkout_notice_and_preserves_optional_fields():
    html = read(FRONTEND / "dados-pessoais" / "index.html")
    profile = read(FRONTEND / "features" / "profile.js")
    css = read(FRONTEND / "css" / "style.css")

    for fragment in [
        "data-checkout-profile-notice",
        "Complete seus dados para continuar a compra.",
        "data-checkout-profile-missing",
        'name="nomeCompleto" type="text" autocomplete="name" placeholder="Seu nome completo" required',
        'name="telefone" type="tel" autocomplete="tel" placeholder="(00) 00000-0000" required',
        'name="nomeDestinatario" type="text" autocomplete="name" required',
        'name="cep" type="text" inputmode="numeric" autocomplete="postal-code" required',
        'name="logradouro" type="text" autocomplete="address-line1" required',
        'name="numero" type="text" autocomplete="address-line2" required',
        'name="bairro" type="text" required',
        'name="cidade" type="text" autocomplete="address-level2" required',
        'name="uf" type="text" maxlength="2" autocomplete="address-level1" required',
        "profile-checkout-notice",
        '[aria-invalid="true"]',
    ]:
        assert fragment in html + css

    for optional_fragment in [
        'name="complemento" type="text" autocomplete="address-line3">',
        'name="referencia" rows="3"',
        'name="avatar" type="file"',
        'name="pagamentoPreferido"',
    ]:
        assert optional_fragment in html

    assert 'new URLSearchParams(window.location.search).get("aviso") === "checkout"' in profile
    assert 'return redirect === "/carrinho/" ? redirect : ""' in profile
    assert "loadOwnProfile(supabase)" in profile
    assert "loadDefaultAddress(supabase)" in profile


def test_web19_rpc_validates_persisted_profile_before_creating_order():
    migration = read(MIGRATION)

    validation_index = migration.index("Complete seus dados pessoais")
    order_insert_index = migration.index("insert into public.shopping_pedidos")
    cart_update_index = migration.index("update public.shopping_carrinhos")

    assert validation_index < order_insert_index < cart_update_index
    for fragment in [
        "v_perfil.nome_completo",
        "v_perfil.email_normalizado",
        "v_perfil.telefone_normalizado",
        "v_endereco_reg.nome_destinatario",
        "v_endereco_reg.cep",
        "v_endereco_reg.logradouro",
        "v_endereco_reg.numero",
        "v_endereco_reg.bairro",
        "v_endereco_reg.cidade",
        "v_endereco_reg.uf",
        "char_length(v_cep_digits) <> 8",
        "revoke all on function public.shopping_pedido_finalizar_carrinho()",
        "grant execute on function public.shopping_pedido_finalizar_carrinho() to authenticated",
    ]:
        assert fragment in migration
