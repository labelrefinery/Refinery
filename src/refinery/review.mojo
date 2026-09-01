"""Apply a reviewer's edits to a label CSV.

Edits arrive as `(track_id, field, new_value)` and are applied to every row of
that track, because a class is a property of the object, not of one frame: a
reviewer looking at a truck and typing "haul_truck" means the truck, for the
whole time it is tracked.

Two things the pipeline's own file format forces, both of which would fail
silently if ignored:

Column order is load-bearing. `refinery.pipeline.read_detections` reads the
tracker CSV **positionally**, so the header is written back exactly as it came
in and no column is reordered, added or dropped.

Rows must stay ascending in `t` and grouped by frame, because the same reader
splits frames on a change in `t`. Rewriting rows in place preserves that; a
rebuild that grouped by track would not.
"""


@fieldwise_init
struct ReviewMetrics(Copyable, ImplicitlyCopyable, Movable):
    var rows: Int
    var edits: Int
    var rows_changed: Int

    def as_json(self) -> String:
        return String(
            '{"rows": ',
            self.rows,
            ', "edits": ',
            self.edits,
            ', "rows_changed": ',
            self.rows_changed,
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


def apply_edits(
    labels_path: String,
    out_path: String,
    edits: List[List[String]],
) raises -> ReviewMetrics:
    """Write `labels_path` to `out_path` with the reviewer's edits applied.

    `edits` is a list of `[track_id, field, new_value]`. An edit naming a
    column the file does not have is skipped rather than fatal -- a reviewer
    should not be able to corrupt a pipeline artefact by typo.
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
    if col_track < 0:
        raise Error("labels CSV has no track_id column: " + labels_path)

    var changed = 0
    var applied = 0
    for e in range(len(edits)):
        ref edit = edits[e]
        if len(edit) < 3:
            continue
        var target = edit[0]
        var col = _column(header, edit[1])
        if col < 0:
            continue
        applied += 1
        for i in range(len(rows)):
            if col_track >= len(rows[i]) or col >= len(rows[i]):
                continue
            if rows[i][col_track] != target:
                continue
            if rows[i][col] != edit[2]:
                rows[i][col] = edit[2]
                changed += 1

    var out = open(out_path, "w")
    var head_line = String("")
    for i in range(len(header)):
        if i > 0:
            head_line += ","
        head_line += header[i]
    out.write(head_line + "\n")
    for i in range(len(rows)):
        var line = String("")
        for c in range(len(rows[i])):
            if c > 0:
                line += ","
            line += rows[i][c]
        out.write(line + "\n")
    out.close()

    var metrics = ReviewMetrics(len(rows), applied, changed)
    print(
        "review:",
        applied,
        "edits changed",
        changed,
        "of",
        len(rows),
        "rows ->",
        out_path,
    )
    return metrics^
