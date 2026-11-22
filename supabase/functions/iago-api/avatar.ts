import { Buffer } from "node:buffer";
import { deflateSync } from "node:zlib";
import { type Body, type Context, fail, type Sql, uuid } from "./common.ts";

const side = 128;
const pixelBytes = side * side * 4;
export const athleteBodyLimit = 96 * 1024;

function chunk(name: string, data: Uint8Array) {
  const result = Buffer.alloc(12 + data.length);
  result.writeUInt32BE(data.length, 0);
  result.write(name, 4, "ascii");
  result.set(data, 8);
  let crc = -1;
  for (const byte of result.subarray(4, -4)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  result.writeUInt32BE((~crc) >>> 0, result.length - 4);
  return result;
}

export function photo(data: Body, editing = false): Buffer | null | undefined {
  const value = data.foto_rgba;
  if (value === undefined) return undefined;
  if (editing && value === null) return null;
  if (data.foto_autorizada !== true || typeof value !== "string" ||
      value.length !== Math.ceil(pixelBytes / 3) * 4 || !/^[A-Za-z0-9+/]+==$/.test(value)) {
    fail(422, "Foto inválida ou sem autorização para publicação.");
  }
  const pixels = Buffer.from(value, "base64");
  if (pixels.length !== pixelBytes || pixels.toString("base64") !== value) fail(422, "Foto inválida.");
  const header = Buffer.alloc(13);
  header.writeUInt32BE(side);
  header.writeUInt32BE(side, 4);
  header[8] = 8;
  header[9] = 6;
  const rows = Buffer.alloc(side * (1 + side * 4));
  for (let y = 0; y < side; y++) {
    rows.set(pixels.subarray(y * side * 4, (y + 1) * side * 4), y * (1 + side * 4) + 1);
  }
  return Buffer.concat([
    Buffer.from("89504e470d0a1a0a", "hex"), chunk("IHDR", header),
    chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0)),
  ]);
}

export async function savePhoto(c: Sql, athleteId: string, png: Buffer | null | undefined) {
  if (png === undefined) return;
  if (png === null) {
    await c`DELETE FROM cadastro.fotos_skatistas WHERE skatista_id=${athleteId}`;
  } else {
    await c`INSERT INTO cadastro.fotos_skatistas(skatista_id,png) VALUES (${athleteId},${png})
      ON CONFLICT (skatista_id) DO UPDATE SET png=excluded.png,versao=excluded.versao`;
  }
}

export async function avatar({ sql, codigo, request, url }: Context, id: string) {
  const version = uuid(url.searchParams.get("v"));
  const [row] = await sql`SELECT f.png FROM cadastro.fotos_skatistas f
    JOIN cadastro.inscricoes i ON i.skatista_id=f.skatista_id
    JOIN cadastro.eventos e ON e.id=i.evento_id
    WHERE i.id=${id} AND f.versao=${version} AND e.codigo=${codigo}`;
  if (!row) fail(404, "Foto indisponível.");
  const etag = `"${version}"`;
  const headers = {
    "Cache-Control": "public, no-cache", ETag: etag, "Content-Type": "image/png",
    "X-Content-Type-Options": "nosniff",
  };
  if (request.headers.get("if-none-match") === etag) return new Response(null, { status: 304, headers });
  return new Response(Uint8Array.from(row.png), { headers });
}
