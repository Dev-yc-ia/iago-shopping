"""Miniaturas públicas geradas a partir de pixels RGBA de tamanho fixo."""

import base64
import binascii
import struct
import zlib

from fastapi import HTTPException

LADO = 128
PIXELS_BYTES = LADO * LADO * 4
LIMITE_JSON = 96 * 1024
MANTER = object()


def _chunk(tipo, dados):
    bloco = tipo + dados
    return struct.pack(">I", len(dados)) + bloco + struct.pack(">I", zlib.crc32(bloco))


def foto(dados, *, edicao=False):
    valor = dados.get("foto_rgba", MANTER)
    if valor is MANTER or (edicao and valor is None):
        return valor
    if (
        dados.get("foto_autorizada") is not True
        or not isinstance(valor, str)
        or len(valor) != ((PIXELS_BYTES + 2) // 3) * 4
    ):
        raise HTTPException(422, "Foto inválida ou sem autorização para publicação.")
    try:
        pixels = base64.b64decode(valor, validate=True)
    except (ValueError, binascii.Error):
        raise HTTPException(422, "Foto inválida.") from None
    if len(pixels) != PIXELS_BYTES or base64.b64encode(pixels).decode() != valor:
        raise HTTPException(422, "Foto inválida.")
    passo = LADO * 4
    linhas = b"".join(
        b"\x00" + pixels[i : i + passo] for i in range(0, len(pixels), passo)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", struct.pack(">IIBBBBB", LADO, LADO, 8, 6, 0, 0, 0))
        + _chunk(b"IDAT", zlib.compress(linhas))
        + _chunk(b"IEND", b"")
    )


def gravar_foto(connection, skatista_id, png):
    if png is MANTER:
        return
    if png is None:
        connection.execute(
            "DELETE FROM cadastro.fotos_skatistas WHERE skatista_id=%s", (skatista_id,)
        )
    else:
        connection.execute(
            """INSERT INTO cadastro.fotos_skatistas(skatista_id,png) VALUES (%s,%s)
            ON CONFLICT (skatista_id) DO UPDATE SET png=excluded.png,versao=excluded.versao""",
            (skatista_id, png),
        )
