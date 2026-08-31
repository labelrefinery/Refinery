// Build Iceberg tables with icebird, staging bytes on local disk while the
// metadata records the final public URLs.
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
//     npx wrangler r2 object put "labelrefinery-samples/datasets/v0.1.0/${f#stage/}" \
//       --file "$f" --remote
//   done
import { mkdir, writeFile, readFile, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { parquetReadObjects } from 'hyparquet'
import { ByteWriter } from 'hyparquet-writer'
import { fileCatalog, icebergAppend, icebergCreateTable } from 'icebird'

// usage: node datasets_publish.mjs <parquet-dir> <stage-dir> [base-url]
const [PARQUET_DIR, STAGE, BASE_ARG] = process.argv.slice(2)
const BASE = BASE_ARG ?? 'https://samples.magmalake.org/datasets/v0.1.0'
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

const TRACKS = {
  type: 'struct',
  'schema-id': 0,
  fields: [
    { id: 1, name: 'instance_id', required: true, type: 'string' },
    { id: 2, name: 'class', required: true, type: 'string' },
    { id: 3, name: 'part', required: false, type: 'string' },
    { id: 4, name: 't', required: true, type: 'double' },
    { id: 5, name: 'x', required: true, type: 'double' },
    { id: 6, name: 'y', required: true, type: 'double' },
    { id: 7, name: 'z', required: true, type: 'double' },
    { id: 8, name: 'w', required: true, type: 'double' },
    { id: 9, name: 'l', required: true, type: 'double' },
    { id: 10, name: 'h', required: true, type: 'double' },
    { id: 11, name: 'theta', required: true, type: 'double' },
    { id: 12, name: 'vx', required: false, type: 'double' },
    { id: 13, name: 'vy', required: false, type: 'double' },
    { id: 14, name: 'num_lidar_points', required: false, type: 'int' },
  ],
}

const LABELS = {
  type: 'struct',
  'schema-id': 0,
  fields: [
    { id: 1, name: 'dataset_name', required: true, type: 'string' },
    { id: 2, name: 'instance_id', required: true, type: 'string' },
    { id: 3, name: 'class', required: false, type: 'string' },
    { id: 4, name: 't', required: true, type: 'double' },
    { id: 5, name: 'x', required: true, type: 'double' },
    { id: 6, name: 'y', required: true, type: 'double' },
    { id: 7, name: 'z', required: true, type: 'double' },
    { id: 8, name: 'w', required: true, type: 'double' },
    { id: 9, name: 'l', required: true, type: 'double' },
    { id: 10, name: 'h', required: true, type: 'double' },
    { id: 11, name: 'theta', required: true, type: 'double' },
    { id: 12, name: 'cls_conf', required: false, type: 'double' },
    { id: 13, name: 'cls_source', required: false, type: 'string' },
    { id: 14, name: 'producer', required: true, type: 'string' },
  ],
}

async function build(name, schema) {
  const file = await readFile(join(PARQUET_DIR, `${name}.parquet`))
  const records = await parquetReadObjects({
    file: { byteLength: file.byteLength, slice: (s, e) => file.buffer.slice(file.byteOffset + s, file.byteOffset + (e ?? file.byteLength)) },
  })
  // hyparquet yields plain numbers; Iceberg `int` columns must be integers and
  // nulls must stay null rather than becoming 0.
  for (const r of records) {
    if (r.num_lidar_points !== null && r.num_lidar_points !== undefined) {
      r.num_lidar_points = Math.round(r.num_lidar_points)
    }
  }

  const catalog = fileCatalog({ resolver })
  const tableUrl = `${BASE}/${name}`
  await icebergCreateTable({ catalog, tableUrl, schema })
  await icebergAppend({ catalog, tableUrl, records })
  console.log(`${name}: ${records.length} rows -> ${tableUrl}`)
  return records.length
}

await mkdir(STAGE, { recursive: true })
await build('ground_truth_tracks', TRACKS)
await build('labels', LABELS)
console.log(`\nstaged under ${STAGE}`)
