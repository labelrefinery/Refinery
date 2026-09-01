"""Drop tracks that never went anywhere.

Motion is the strongest signal geometry has, and this is the stage the whole
loop turns on: trained on unfiltered labels the student went backwards, trained
on filtered ones it beat its own supervision. The filter is what decides which.

Ported from `steps.filter_labels`. One deliberate difference: the Python version
writes with `csv.DictWriter(fieldnames=TRACKER_HEADER)`, which silently drops
`cls_conf` and `cls_source` — so a name that `name_instances` worked out, or a
reviewer corrected, survived to training only in `cls`. This keeps every column
the input had.
"""

from std.math import sqrt


comptime TRACKER_HEADER = "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf"


@fieldwise_init
struct FilterMetrics(Copyable, ImplicitlyCopyable, Movable):
    var rows_in: Int
    var rows_out: Int
    var tracks_in: Int
    var tracks_dropped: Int

    def as_json(self) -> String:
        return String(
            '{"in": ',
            self.rows_in,
            ', "out": ',
            self.rows_out,
            ', "tracks": ',
            self.tracks_in,
            ', "tracks_dropped": ',
            self.tracks_dropped,
            "}",
        )


def _split_line(line: String) -> List[String]:
    var out = List[String]()
    for part in line.split(","):
        out.append(String(part))
    return out^


def _column(header: List[String], name: String) -> Int:
    for i in range(len(header)):
        if header[i] == name:
            return i
    return -1


def filter_labels(
    labels_path: String, out_path: String, min_path_m: Float64 = 4.0
) raises -> FilterMetrics:
    """Keep only tracks whose 2-D path length reaches `min_path_m`.

    A track is kept or dropped whole: a stationary stretch inside a track that
    otherwise moves is still that object, and cutting it would fragment the
    trajectory the smoother just produced.
    """
    var handle = open(labels_path, "r")
    var text = handle.read()
    handle.close()

    var header = List[String]()
    var rows = List[List[String]]()
    var first = True
    for raw in text.split("\n"):
        var line = String(String(raw).strip())
        if line.byte_length() == 0:
            continue
        if first:
            header = _split_line(line)
            first = False
            continue
        rows.append(_split_line(line))

    var col_track = _column(header, "track_id")
    var col_t = _column(header, "t")
    var col_x = _column(header, "x")
    var col_y = _column(header, "y")
    if col_track < 0 or col_t < 0 or col_x < 0 or col_y < 0:
        raise Error(
            "labels CSV is missing one of track_id/t/x/y: " + labels_path
        )

    # Group row indices by track, preserving file order within a track. The
    # tracker writes each track's rows already ascending in t.
    var track_ids = List[String]()
    var track_rows = List[List[Int]]()
    for i in range(len(rows)):
        if col_track >= len(rows[i]):
            continue
        var tid = rows[i][col_track]
        var found = -1
        for k in range(len(track_ids)):
            if track_ids[k] == tid:
                found = k
                break
        if found < 0:
            track_ids.append(tid)
            var fresh = List[Int]()
            fresh.append(i)
            track_rows.append(fresh^)
        else:
            track_rows[found].append(i)

    var keep = List[Bool]()
    for _ in range(len(rows)):
        keep.append(False)

    var dropped = 0
    for k in range(len(track_ids)):
        ref idxs = track_rows[k]
        var path_m = 0.0
        for j in range(1, len(idxs)):
            var prev = idxs[j - 1]
            var cur = idxs[j]
            var dx = Float64(rows[cur][col_x]) - Float64(rows[prev][col_x])
            var dy = Float64(rows[cur][col_y]) - Float64(rows[prev][col_y])
            path_m += sqrt(dx * dx + dy * dy)
        if path_m >= min_path_m:
            for j in range(len(idxs)):
                keep[idxs[j]] = True
        else:
            dropped += 1

    var out = open(out_path, "w")
    var head_line = String("")
    for i in range(len(header)):
        if i > 0:
            head_line += ","
        head_line += header[i]
    out.write(head_line + "\n")

    var written = 0
    for i in range(len(rows)):
        if not keep[i]:
            continue
        var line = String("")
        for c in range(len(rows[i])):
            if c > 0:
                line += ","
            line += rows[i][c]
        out.write(line + "\n")
        written += 1
    out.close()

    var metrics = FilterMetrics(len(rows), written, len(track_ids), dropped)
    print(
        "filter:",
        len(rows),
        "->",
        written,
        "rows |",
        dropped,
        "of",
        len(track_ids),
        "tracks dropped ->",
        out_path,
    )
    return metrics^
