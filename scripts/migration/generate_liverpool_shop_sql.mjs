import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(scriptDir, "../..");
const sourcePath = path.join(
  projectRoot,
  "uk_data/liverpool_shops_with_coords_images.json",
);
const outputPath = path.join(
  projectRoot,
  "src/main/resources/db/migration/R__liverpool_shop_catalog.sql",
);

const columns = [
  "id",
  "name",
  "type_id",
  "images",
  "area",
  "address",
  "x",
  "y",
  "avg_price",
  "sold",
  "comments",
  "score",
  "open_hours",
];

const rows = JSON.parse(await fs.readFile(sourcePath, "utf8"));

if (!Array.isArray(rows) || rows.length !== 59) {
  throw new Error(`Expected 59 Liverpool shops, received ${rows.length}`);
}

const ids = new Set();
for (const row of rows) {
  for (const column of columns) {
    if (!(column in row)) {
      throw new Error(`Shop ${row.id ?? "unknown"} is missing column ${column}`);
    }
  }
  if (!Number.isInteger(row.id) || row.id < 900001 || row.id > 900059) {
    throw new Error(`Shop id is outside the managed range: ${row.id}`);
  }
  if (ids.has(row.id)) {
    throw new Error(`Duplicate shop id: ${row.id}`);
  }
  ids.add(row.id);
  if (!Number.isInteger(row.type_id) || row.type_id < 1 || row.type_id > 10) {
    throw new Error(`Invalid type_id for shop ${row.id}: ${row.type_id}`);
  }
  if (typeof row.x !== "number" || typeof row.y !== "number") {
    throw new Error(`Missing coordinates for shop ${row.id}`);
  }
  if ((row.open_hours?.length ?? 0) > 128) {
    throw new Error(`open_hours is too long for shop ${row.id}`);
  }
}

const expectedTypes = new Map([
  [900046, 10],
  [900047, 10],
  [900058, 4],
  [900059, 4],
]);
for (const [id, typeId] of expectedTypes) {
  const row = rows.find((item) => item.id === id);
  if (row?.type_id !== typeId) {
    throw new Error(`Shop ${id} must use type_id ${typeId}`);
  }
}

function sqlValue(value) {
  if (value === null || value === undefined || value === "") {
    return "NULL";
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error(`Non-finite number in source data: ${value}`);
    }
    return String(value);
  }
  return `'${String(value).replaceAll("\\", "\\\\").replaceAll("'", "''")}'`;
}

const values = rows
  .map((row) => `  (${columns.map((column) => sqlValue(row[column])).join(", ")})`)
  .join(",\n");

const updates = columns
  .filter((column) => column !== "id")
  .map((column) => `  ${column} = VALUES(${column})`)
  .join(",\n");

const sql = `-- Generated from uk_data/liverpool_shops_with_coords_images.json.
-- Re-run scripts/migration/generate_liverpool_shop_sql.mjs after changing the source data.
INSERT INTO tb_shop (
  ${columns.join(", ")}
)
VALUES
${values}
ON DUPLICATE KEY UPDATE
${updates};
`;

await fs.writeFile(outputPath, sql, "utf8");
console.log(`Generated ${path.relative(projectRoot, outputPath)} with ${rows.length} shops.`);
