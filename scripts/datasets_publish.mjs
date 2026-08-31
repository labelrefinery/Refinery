// Turn dataset Parquet into Iceberg tables, staging bytes on local disk while
// the metadata records the final public URLs.
//
// Iceberg metadata stores absolute file locations. PyIceberg writes `file://…`
// paths, which a browser cannot fetch, so the table has to be authored with the
// URL it will be served from. Writing it with icebird also guarantees the
// reader on the site can read it -- same library, both ends.
//
//   npm install icebird hyparquet hyparquet-writer
//   python scripts/datasets_from_mcap.py scene.mcap labels.mcap ./parquet
//   node   scripts/datasets_publish.mjs  ./parquet ./stage
//   for f in $(find stage -type f); do
//     npx wrangler r2 object put "labelrefinery-samples/datasets/v0.2.0/${f#stage/}" \
//       --file "$f" --remote
//   done
import { mkdir, writeFile, readFile, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { parquetMetadata, parquetReadObjects } from 'hyparquet'
import { ByteWriter } from 'hyparquet-writer'
import { fileCatalog, icebergAppend, icebergCreateTable } from 'icebird'

// usage: node datasets_publish.mjs <parquet-dir> <stage-dir> [base-url]
const [PARQUET_DIR, STAGE, BASE_ARG] = process.argv.slice(2)
const BASE = BASE_ARG ?? 'https://samples.magmalake.org/datasets/v0.2.0'
if (!PARQUET_DIR || !STAGE) {
  console.error('usage: node datasets_publish.mjs <parquet-dir> <stage-dir> [base-url]')
  process.exit(2)
}

/** Map a public URL back to its staged path on disk. */
function toLocal(url) {
  if (!url.startsWith(BASE)) throw new Error(`unexpected path outside base: ${url}`)
  return join(STAGE, url.slice(BASE.length))
}

const resolver = {
  async reader(url, byteLength) {
    const path = toLocal(url)
    const size = byteLength ?? (await stat(path)).size
    return {
      byteLength: size,
      async slice(start, end) {
        const buf = await readFile(path)
        return buf.buffer.slice(
          buf.byteOffset + start,
          buf.byteOffset + (end ?? size)
        )
      },
    }
  },
  writer(url) {
    const w = new ByteWriter()
    w.finish = async function () {
      const path = toLocal(url)
      await mkdir(dirname(path), { recursive: true })
      await writeFile(path, Buffer.from(w.getBytes()))
    }
    return w
  },
}

/** Iceberg schema derived from the Parquet, so there is no second copy to drift. */
function schemaFromParquet(meta) {
  const TYPES = {
    DOUBLE: 'double',
    FLOAT: 'float',
    INT32: 'int',
    INT64: 'long',
    BYTE_ARRAY: 'string',
    BOOLEAN: 'boolean',
  }
  const fields = []
  let id = 1
  for (const el of meta.schema) {
    if (!el.type) continue // the root element carries no type
    const type = TYPES[el.type]
    if (!type) throw new Error(`unmapped parquet type ${el.type} for ${el.name}`)
    fields.push({
      id: id++,
      name: el.name,
      required: el.repetition_type === 'REQUIRED',
      type,
    })
  }
  return { type: 'struct', 'schema-id': 0, fields }
}

async function build(name) {
  const buf = await readFile(join(PARQUET_DIR, `${name}.parquet`))
  const file = {
    byteLength: buf.byteLength,
    slice: (s, e) =>
      buf.buffer.slice(buf.byteOffset + s, buf.byteOffset + (e ?? buf.byteLength)),
  }
  const schema = schemaFromParquet(parquetMetadata(buf.buffer.slice(
    buf.byteOffset, buf.byteOffset + buf.byteLength)))
  const records = await parquetReadObjects({ file })

  // Iceberg `int` columns must hold integers, and a null must stay null rather
  // than being coerced to 0 -- for num_lidar_points the difference is
  // "seen and got no returns" versus "no labelled sweep at this timestamp".
  const ints = new Set(schema.fields.filter(f => f.type === 'int').map(f => f.name))
  for (const r of records) {
    for (const k of ints) {
      if (r[k] !== null && r[k] !== undefined) r[k] = Math.round(r[k])
    }
  }

  const catalog = fileCatalog({ resolver })
  const tableUrl = `${BASE}/${name}`
  await icebergCreateTable({ catalog, tableUrl, schema })
  await icebergAppend({ catalog, tableUrl, records })
  console.log(
    `${name}: ${records.length} rows, ${schema.fields.length} columns -> ${tableUrl}`
  )
}

await mkdir(STAGE, { recursive: true })
await build('ground_truth_tracks')
await build('labels')
console.log(`\nstaged under ${STAGE}`)
