import { inflateRawSync } from "node:zlib";
import { DOMParser } from "npm:@xmldom/xmldom@0.9.12";
import { fail } from "./common.ts";

const maxInflated = 40 * 1024 * 1024;
const invalid = () => new Error("XLSX inválido");
const decoder = new TextDecoder("utf-8", { fatal: true });

function unpack(data: Uint8Array) {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const u16 = (i: number) => view.getUint16(i, true);
  const u32 = (i: number) => view.getUint32(i, true);
  let end = data.length - 22;
  while (end >= Math.max(0, data.length - 65557)) {
    if (u32(end) === 0x06054b50 && end + 22 + u16(end + 20) === data.length) break;
    end--;
  }
  if (end < Math.max(0, data.length - 65557) || u16(end + 4) || u16(end + 6)) throw invalid();
  const count = u16(end + 10);
  const start = u32(end + 16);
  if (count !== u16(end + 8) || count > 2048 || start + u32(end + 12) !== end) throw invalid();
  let offset = start;
  let total = 0;
  const entries = new Map<string, () => Uint8Array>();
  for (let i = 0; i < count; i++) {
    if (offset + 46 > end || u32(offset) !== 0x02014b50) throw invalid();
    const flags = u16(offset + 8);
    const method = u16(offset + 10);
    const packed = u32(offset + 20);
    const size = u32(offset + 24);
    const nameLen = u16(offset + 28);
    const local = u32(offset + 42);
    const name = decoder.decode(data.subarray(offset + 46, offset + 46 + nameLen));
    offset += 46 + nameLen + u16(offset + 30) + u16(offset + 32);
    if (offset > end || (flags & 1) || entries.has(name) || ![0, 8].includes(method)) throw invalid();
    if (/vbaproject/i.test(name)) fail(422, "Use uma planilha sem macros.");
    total += size;
    if (total > maxInflated) fail(422, "Planilha excede o limite descompactado.");
    if (local + 30 > start || u32(local) !== 0x04034b50 || u16(local + 8) !== method) throw invalid();
    const from = local + 30 + u16(local + 26) + u16(local + 28);
    if (from + packed > start) throw invalid();
    entries.set(name, () => {
      const source = data.subarray(from, from + packed);
      const output = method === 0 ? source : inflateRawSync(source, { maxOutputLength: Math.max(size, 1) });
      if (output.length !== size) throw invalid();
      return output;
    });
  }
  if (offset !== end) throw invalid();
  return entries;
}
export function readXlsx(data: Uint8Array): unknown[][] {
  const entries = unpack(data);
  const xml = (path: string) => {
    const read = entries.get(path);
    if (!read) throw invalid();
    const text = decoder.decode(read());
    if (/<!DOCTYPE|<!ENTITY/i.test(text)) throw invalid();
    return new DOMParser().parseFromString(text, "application/xml");
  };
  const workbook = xml("xl/workbook.xml");
  const sheet = workbook.getElementsByTagNameNS("*", "sheet").item(0);
  const relId = sheet?.getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id");
  if (!relId) throw invalid();
  const rels = xml("xl/_rels/workbook.xml.rels");
  const rel = Array.from(rels.getElementsByTagNameNS("*", "Relationship")).find((node) => node.getAttribute("Id") === relId);
  const target = rel?.getAttribute("Target");
  if (!target || !rel?.getAttribute("Type")?.endsWith("/worksheet") || rel.getAttribute("TargetMode") === "External") throw invalid();
  const path = new URL(target, "https://xlsx.invalid/xl/workbook.xml");
  if (path.origin !== "https://xlsx.invalid") throw invalid();
  const sheetDoc = xml(decodeURIComponent(path.pathname.slice(1)));
  const rows = Array.from(sheetDoc.getElementsByTagNameNS("*", "row"));
  const date1904 = ["1", "true"].includes(workbook.getElementsByTagNameNS("*", "workbookPr").item(0)?.getAttribute("date1904") ?? "");
  const strings = entries.has("xl/sharedStrings.xml")
    ? Array.from(xml("xl/sharedStrings.xml").getElementsByTagNameNS("*", "si"), (node) => node.textContent ?? "")
    : [];
  const dateFormats = new Set([14, 15, 16, 17, 22, 27, 28, 29, 30, 31, 34, 35, 36, 50, 51, 52, 53, 54, 57, 58]);
  const styles = entries.has("xl/styles.xml") ? xml("xl/styles.xml") : null;
  for (const fmt of Array.from(styles?.getElementsByTagNameNS("*", "numFmt") ?? [])) {
    const code = fmt.getAttribute("formatCode")?.replace(/"[^"]*"|\\.|\[[^\]]*\]/g, "") ?? "";
    if (/[dy]/i.test(code)) dateFormats.add(Number(fmt.getAttribute("numFmtId")));
  }
  const dates = Array.from(styles?.getElementsByTagNameNS("*", "cellXfs").item(0)?.getElementsByTagNameNS("*", "xf") ?? [],
    (node) => dateFormats.has(Number(node.getAttribute("numFmtId"))));
  const output: unknown[][] = [];
  for (const row of rows) {
    const n = row.hasAttribute("r") ? Number(row.getAttribute("r")) : output.length + 1;
    if (!Number.isInteger(n) || n <= output.length) throw invalid();
    if (n > 1001) fail(422, "Limite de 1000 linhas excedido.");
    const fields: unknown[] = [];
    for (const cell of Array.from(row.getElementsByTagNameNS("*", "c"))) {
      if (cell.getElementsByTagNameNS("*", "f").length) fail(422, `Linha ${n}: fórmulas não são aceitas.`);
      const ref = /^([A-Z]{1,3})[1-9]\d*$/.exec(cell.getAttribute("r") ?? "");
      const index = ref ? [...ref[1]].reduce((col, ch) => col * 26 + ch.charCodeAt(0) - 64, 0) - 1 : fields.length;
      if (index > 16383) throw invalid();
      const v = cell.getElementsByTagNameNS("*", "v").item(0)?.textContent;
      let value: unknown = null;
      const kind = cell.getAttribute("t");
      if (kind === "inlineStr") value = cell.getElementsByTagNameNS("*", "is").item(0)?.textContent ?? "";
      else if (v != null) {
        if (kind === "s") {
          value = strings[Number(v)];
          if (value === undefined) throw invalid();
        } else if (kind === "d") {
          value = v.slice(0, 10);
        } else if (kind === "n" || !kind) {
          const number = Number(v);
          if (!Number.isFinite(number)) throw invalid();
          if (dates[Number(cell.getAttribute("s") ?? 0)]) {
            const days = Math.floor(number);
            const epoch = Date.UTC(date1904 ? 1904 : 1899, date1904 ? 0 : 11, date1904 ? 1 : 30);
            value = new Date(epoch + (days + (!date1904 && days < 60 ? 1 : 0)) * 86400000).toISOString().slice(0, 10);
          } else value = number;
        } else value = kind === "str" ? v : null;
      }
      while (fields.length <= index) fields.push(null);
      fields[index] = value;
    }
    while (output.length < n - 1) output.push([]);
    output.push(fields);
  }
  return output;
}
