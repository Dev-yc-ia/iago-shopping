"""Cadastro recorrente, com validação e gravação atômica."""

import csv
from datetime import date, datetime
from io import BytesIO, StringIO
from xml.etree.ElementTree import ParseError
from zipfile import BadZipFile, ZipFile

from fastapi import HTTPException
from openpyxl import load_workbook
from openpyxl.utils.exceptions import InvalidFileException
from psycopg import Error
from psycopg.errors import UniqueViolation

from backend.db import write_connection
from backend.security import sessao
from backend.services.avatar import MANTER, gravar_foto
from backend.services.votacao import bloquear_evento
from scripts.importar_skatistas import CABECALHO, Registro, chave_origem

LIMITE_BYTES = 2 * 1024 * 1024
LIMITE_LINHAS = 1000


def validar_linha(campos, evento, linha):
    if len(campos) != 6 or any(valor is None for valor in campos):
        raise ValueError(f"Linha {linha}: preencha as seis colunas.")
    nome, escola, nascimento, ano, sexo, categoria = campos
    if isinstance(nascimento, datetime):
        nascimento = nascimento.date()
    try:
        if isinstance(nascimento, str):
            texto = nascimento.strip()
            nascimento = date.fromisoformat(texto)
            if nascimento.isoformat() != texto:
                raise ValueError
        if (
            not isinstance(nascimento, date)
            or not date(1900, 1, 1) <= nascimento <= date.today()
        ):
            raise ValueError
        if str(ano).strip() != str(nascimento.year):
            raise ValueError
    except ValueError:
        raise ValueError(f"Linha {linha}: data ou ano inválido.") from None
    textos = (nome, escola, sexo, categoria)
    if any(
        not isinstance(valor, str)
        or not 1 <= len(valor.strip()) <= 200
        or "\x00" in valor
        or valor.lstrip().startswith("=")
        for valor in textos
    ):
        raise ValueError(f"Linha {linha}: campos de texto inválidos.")
    nome, escola, sexo, categoria = (valor.strip() for valor in textos)
    if sexo not in {"Masculino", "Feminino"}:
        raise ValueError(f"Linha {linha}: sexo confirmado inválido.")
    return Registro(
        nome,
        escola,
        nascimento,
        sexo,
        categoria,
        chave_origem(evento, nome, nascimento),
    )


def ler_linhas(linhas, evento):
    if list(next(linhas, ())) != CABECALHO:
        raise ValueError("Cabeçalho inválido. Use o modelo de importação.")
    registros = []
    for numero, campos in enumerate(linhas, 2):
        if numero > LIMITE_LINHAS + 1:
            raise ValueError(f"Limite de {LIMITE_LINHAS} linhas excedido.")
        if all(valor in (None, "") for valor in campos):
            continue
        registros.append((numero, validar_linha(campos, evento, numero)))
    if not registros:
        raise ValueError("A planilha está vazia.")
    return registros


def ler_planilha(nome, conteudo, evento):
    try:
        if nome.lower().endswith(".csv"):
            return ler_linhas(
                csv.reader(
                    StringIO(conteudo.decode("utf-8-sig")), delimiter=";", strict=True
                ),
                evento,
            )
        if nome.lower().endswith(".xlsx"):
            with ZipFile(BytesIO(conteudo)) as arquivo:
                if (
                    sum(item.file_size for item in arquivo.infolist())
                    > 20 * LIMITE_BYTES
                ):
                    raise ValueError("Planilha excede o limite descompactado.")
                if any(
                    "vbaproject" in item.filename.lower() for item in arquivo.infolist()
                ):
                    raise ValueError("Use uma planilha sem macros.")
            livro = load_workbook(
                BytesIO(conteudo), read_only=True, data_only=False, keep_links=False
            )
            try:
                aba = livro.worksheets[0]
                aba.reset_dimensions()

                def linhas():
                    for numero, celulas in enumerate(aba.iter_rows(), 1):
                        if any(celula.data_type == "f" for celula in celulas):
                            raise ValueError(
                                f"Linha {numero}: fórmulas não são aceitas."
                            )
                        yield [celula.value for celula in celulas]

                return ler_linhas(linhas(), evento)
            finally:
                livro.close()
    except (
        UnicodeError,
        csv.Error,
        BadZipFile,
        KeyError,
        IndexError,
        OSError,
        InvalidFileException,
        ParseError,
    ):
        raise ValueError(
            "Arquivo inválido. Use XLSX ou CSV UTF-8 separado por ponto e vírgula."
        ) from None
    raise ValueError("Use um arquivo .xlsx ou .csv.")


def gravar_lote(settings, request, registros, png=MANTER):
    incluidos = duplicados = 0
    pessoa_nova = False
    with write_connection(settings) as c:
        sessao(c, request, perfil="master", bloquear=True)
        c.execute(
            "SELECT pg_advisory_xact_lock(hashtext(%s))", (settings.evento_codigo,)
        )
        evento = c.execute(
            "SELECT id FROM cadastro.eventos WHERE codigo=%s", (settings.evento_codigo,)
        ).fetchone()
        if not evento:
            raise HTTPException(409, "Evento sem cadastro.")
        for linha, registro in registros:
            try:
                inscricao = c.execute(
                    "SELECT * FROM cadastro.incluir_inscricao(%s,%s,%s,%s,%s,%s,%s)",
                    (
                        evento["id"],
                        registro.chave,
                        registro.nome,
                        registro.escola,
                        registro.nascimento,
                        registro.sexo,
                        registro.categoria,
                    ),
                ).fetchone()
            except Error as erro:
                if erro.sqlstate in {"IA409", "IA422"}:
                    raise HTTPException(
                        int(erro.sqlstate[2:]),
                        f"Linha {linha}: {erro.diag.message_primary}",
                    ) from None
                raise
            pessoa_nova = pessoa_nova or inscricao["pessoa_nova"]
            if inscricao["incluido"]:
                incluidos += 1
            else:
                duplicados += 1
        if png is not MANTER:
            if not pessoa_nova:
                raise HTTPException(
                    409, "Cadastro existente. Use Editar para publicar uma foto."
                )
            gravar_foto(c, inscricao["pessoa"], png)
    return {"incluidos": incluidos, "duplicados": duplicados}


def editar(settings, request, inscricao_id, registro, categorias=None, png=MANTER):
    try:
        with write_connection(settings) as c:
            evento = bloquear_evento(c, settings)
            sessao(c, request, perfil="master", bloquear=True)
            c.execute(
                "SELECT pg_advisory_xact_lock(hashtext(%s))", (settings.evento_codigo,)
            )
            pessoa = c.execute(
                "SELECT cadastro.editar_inscricoes(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) AS id",
                (
                    evento,
                    inscricao_id,
                    registro.chave,
                    registro.nome,
                    registro.escola,
                    registro.nascimento,
                    registro.sexo,
                    categorias or [registro.categoria],
                    categorias is None,
                    png is not MANTER,
                ),
            ).fetchone()
            gravar_foto(c, pessoa["id"], png)
    except UniqueViolation:
        raise HTTPException(409, "Já existe inscrição nessa categoria.") from None
    except Error as erro:
        if erro.sqlstate in {"IA404", "IA409", "IA422"}:
            raise HTTPException(
                int(erro.sqlstate[2:]), erro.diag.message_primary
            ) from None
        raise
    return {"atualizado": True}
