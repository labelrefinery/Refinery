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


def is_safe_value(v: String) -> Bool:
    """Reject anything that would change the CSV's shape.

    This matters more than it looks. `refinery.pipeline.read_detections` reads
    the tracker CSV **positionally**, so a comma inside a class name shifts
    every column after it -- t becomes x, w becomes h -- and the pipeline reads
    plausible wrong geometry rather than failing. A newline splits one row into
    two. Neither is detectable downstream, so it has to be refused here.

    A leading `=`, `+`, `-` or `@` is refused too: those make a spreadsheet
    treat the cell as a formula when someone opens the CSV to check the labels.
    """
    if v.byte_length() == 0 or v.byte_length() > 64:
        return False
    var first = String(v[byte=0])
    if first == "=" or first == "+" or first == "-" or first == "@":
        return False
    for i in range(v.byte_length()):
        var c = String(v[byte=i])
        if c == "," or c == "\n" or c == "\r" or c == '"':
            return False
    return True


@fieldwise_init
struct ReviewMetrics(Copyable, ImplicitlyCopyable, Movable):
    var rows: Int
    var edits: Int
    var rows_changed: Int
    var rejected: Int

    def as_json(self) -> String:
        return String(
            '{"rows": ',
            self.rows,
            ', "edits": ',
            self.edits,
            ', "rows_changed": ',
            self.rows_changed,
            ', "rejected": ',
            self.rejected,
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


def apply_gold(
    labels_path: String,
    out_path: String,
    decisions: List[List[String]],
) raises -> ReviewMetrics:
    """Build a gold set: keep the tracks a person vouched for, with their names.

    Different from `apply_edits` in the one way that matters. A review corrects
    a machine's labels and every row survives; gold *authors* a reference set,
    so a track nobody vouched for is dropped rather than kept unchanged. The
    default is therefore exclusion — an unanswered track does not quietly
    become truth.

    `decisions` carries `[track_id, "keep", "1"]` and `[track_id, "cls", name]`.
    `cls_source` is set to `gold` on every surviving row, so a downstream
    consumer can tell a human's claim from a detector's.
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
    var col_cls = _column(header, "cls")
    if col_track < 0:
        raise Error("labels CSV has no track_id column: " + labels_path)

    # cls_source belongs on a gold row, so add the column when it is absent.
    var col_src = _column(header, "cls_source")
    if col_src < 0:
        header.append(String("cls_source"))
        col_src = len(header) - 1
        for i in range(len(rows)):
            while len(rows[i]) < len(header):
                rows[i].append(String(""))

    var kept_ids = List[String]()
    var named_ids = List[String]()
    var names = List[String]()
    var rejected = 0
    for d in range(len(decisions)):
        ref one = decisions[d]
        if len(one) < 3:
            continue
        if one[1] == "keep" and one[2] == "1":
            kept_ids.append(one[0])
        elif one[1] == "cls":
            if not is_safe_value(one[2]):
                rejected += 1
                continue
            named_ids.append(one[0])
            names.append(one[2])

    var out = open(out_path, "w")
    var head_line = String("")
    for i in range(len(header)):
        if i > 0:
            head_line += ","
        head_line += header[i]
    out.write(head_line + "\n")

    var written = 0
    var kept_tracks = List[String]()
    for i in range(len(rows)):
        if col_track >= len(rows[i]):
            continue
        var tid = rows[i][col_track]
        var keep = False
        for k in range(len(kept_ids)):
            if kept_ids[k] == tid:
                keep = True
        if not keep:
            continue
        for k in range(len(named_ids)):
            if named_ids[k] == tid and col_cls >= 0 and col_cls < len(rows[i]):
                rows[i][col_cls] = names[k]
        if col_src < len(rows[i]):
            rows[i][col_src] = String("gold")
        var line = String("")
        for c in range(len(rows[i])):
            if c > 0:
                line += ","
            line += rows[i][c]
        out.write(line + "\n")
        written += 1
        var seen = False
        for k in range(len(kept_tracks)):
            if kept_tracks[k] == tid:
                seen = True
        if not seen:
            kept_tracks.append(tid)
    out.close()

    var metrics = ReviewMetrics(len(rows), len(kept_tracks), written, rejected)
    print(
        "gold:",
        len(kept_tracks),
        "tracks kept,",
        written,
        "of",
        len(rows),
        "rows,",
        rejected,
        "names rejected ->",
        out_path,
    )
    return metrics^


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
    var rejected = 0
    for e in range(len(edits)):
        ref edit = edits[e]
        if len(edit) < 3:
            continue
        var target = edit[0]
        var col = _column(header, edit[1])
        if col < 0:
            continue
        if not is_safe_value(edit[2]):
            rejected += 1
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

    var metrics = ReviewMetrics(len(rows), applied, changed, rejected)
    print(
        "review:",
        applied,
        "edits changed",
        changed,
        "of",
        len(rows),
        "rows,",
        rejected,
        "rejected ->",
        out_path,
    )
    return metrics^
