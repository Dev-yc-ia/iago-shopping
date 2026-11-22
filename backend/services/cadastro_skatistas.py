"""Cadastro recorrente, com validação e gravação atômica."""

import csv
from datetime import date, datetime
from io import BytesIO, StringIO
from xml.etree.ElementTree import ParseError
from zipfile import BadZipFile, ZipFile

from fastapi import HTTPException
from openpyxl import load_workbook
from openpyxl.utils.exceptions import InvalidFileException
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
    with write_connection(settings) as c:
        sessao(c, request, perfil="master", bloquear=True)
        # Compartilha a trava de alocação com o importador inicial.
        c.execute(
            "SELECT pg_advisory_xact_lock(hashtext(%s))", (settings.evento_codigo,)
        )
        evento = c.execute(
            "SELECT id FROM cadastro.eventos WHERE codigo=%s", (settings.evento_codigo,)
        ).fetchone()
        if not evento:
            raise HTTPException(409, "Evento sem cadastro.")
        evento_id = evento["id"]
        categorias = {
            row["codigo"]: row["id"]
            for row in c.execute(
                "SELECT id,codigo FROM cadastro.categorias WHERE evento_id=%s",
                (evento_id,),
            )
        }
        existentes = {
            row["chave_origem"]: (
                row["escola"],
                row["sexo_confirmado"],
                row["categoria_base_id"],
            )
            for row in c.execute(
                """SELECT i.chave_origem,s.escola,s.sexo_confirmado,i.categoria_base_id
                FROM cadastro.inscricoes i JOIN cadastro.skatistas s ON s.id=i.skatista_id
                WHERE i.evento_id=%s""",
                (evento_id,),
            )
        }
        novos = []
        duplicados = 0
        for linha, registro in registros:
            if registro.categoria not in categorias:
                raise HTTPException(
                    422, f"Linha {linha}: categoria-base indisponível no evento."
                )
            atributos = (registro.escola, registro.sexo, categorias[registro.categoria])
            if registro.chave in existentes:
                if existentes[registro.chave] != atributos:
                    raise HTTPException(
                        409,
                        f"Linha {linha}: identidade já cadastrada com dados divergentes.",
                    )
                duplicados += 1
                continue
            existentes[registro.chave] = atributos
            novos.append(registro)
        if png is not MANTER and duplicados:
            raise HTTPException(
                409, "Cadastro existente. Use Editar para publicar uma foto."
            )
        maior_numero = c.execute(
            "SELECT coalesce(max(numero_provisorio),0) AS numero FROM cadastro.inscricoes WHERE evento_id=%s",
            (evento_id,),
        ).fetchone()["numero"]
        for numero, registro in enumerate(novos, maior_numero + 1):
            skatista = c.execute(
                """INSERT INTO cadastro.skatistas(nome,escola,data_nascimento,sexo_confirmado)
                VALUES (%s,%s,%s,%s) RETURNING id""",
                (registro.nome, registro.escola, registro.nascimento, registro.sexo),
            ).fetchone()
            c.execute(
                """INSERT INTO cadastro.inscricoes(evento_id,skatista_id,chave_origem,categoria_base_id,numero_provisorio)
                VALUES (%s,%s,%s,%s,%s)""",
                (
                    evento_id,
                    skatista["id"],
                    registro.chave,
                    categorias[registro.categoria],
                    numero,
                ),
            )
            gravar_foto(c, skatista["id"], png)
    return {"incluidos": len(novos), "duplicados": duplicados}


def editar(settings, request, inscricao_id, registro, png=MANTER):
    try:
        with write_connection(settings) as c:
            evento = bloquear_evento(c, settings)
            sessao(c, request, perfil="master", bloquear=True)
            c.execute(
                "SELECT pg_advisory_xact_lock(hashtext(%s))", (settings.evento_codigo,)
            )
            atual = c.execute(
                """SELECT i.skatista_id,s.nome,s.escola,s.data_nascimento,s.sexo_confirmado,
                          i.categoria_base_id
                FROM cadastro.inscricoes i JOIN cadastro.skatistas s ON s.id=i.skatista_id
                WHERE i.id=%s AND i.evento_id=%s FOR UPDATE OF s""",
                (inscricao_id, evento),
            ).fetchone()
            if not atual:
                raise HTTPException(404, "Inscrição não encontrada.")
            categoria = c.execute(
                "SELECT id FROM cadastro.categorias WHERE evento_id=%s AND codigo=%s",
                (evento, registro.categoria),
            ).fetchone()
            if not categoria:
                raise HTTPException(422, "Categoria-base indisponível no evento.")
            if c.execute(
                "SELECT 1 FROM operacao.tentativas WHERE inscricao_id=%s AND estado IN ('chamada','aberta')",
                (inscricao_id,),
            ).fetchone():
                raise HTTPException(
                    409, "Conclua ou cancele a volta em pista antes de editar."
                )
            identidade = (
                atual["nome"] != registro.nome
                or atual["data_nascimento"] != registro.nascimento
            )
            dados = (
                identidade
                or atual["escola"] != registro.escola
                or atual["sexo_confirmado"] != registro.sexo
            )
            if (dados or png is not MANTER) and c.execute(
                "SELECT 1 FROM cadastro.inscricoes WHERE skatista_id=%s AND id<>%s LIMIT 1",
                (atual["skatista_id"], inscricao_id),
            ).fetchone():
                raise HTTPException(
                    409,
                    "Skatista com outras inscrições. Apenas a categoria-base pode ser editada nesta ficha.",
                )
            if dados:
                c.execute(
                    "UPDATE cadastro.skatistas SET nome=%s,escola=%s,data_nascimento=%s,sexo_confirmado=%s WHERE id=%s",
                    (
                        registro.nome,
                        registro.escola,
                        registro.nascimento,
                        registro.sexo,
                        atual["skatista_id"],
                    ),
                )
            if identidade:
                c.execute(
                    "UPDATE cadastro.inscricoes SET chave_origem=%s WHERE id=%s",
                    (registro.chave, inscricao_id),
                )
            if categoria["id"] != atual["categoria_base_id"]:
                c.execute(
                    "UPDATE cadastro.inscricoes SET categoria_base_id=%s WHERE id=%s",
                    (categoria["id"], inscricao_id),
                )
            gravar_foto(c, atual["skatista_id"], png)
    except UniqueViolation:
        raise HTTPException(
            409, "Já existe cadastro com esse nome e nascimento."
        ) from None
    return {"atualizado": True}
