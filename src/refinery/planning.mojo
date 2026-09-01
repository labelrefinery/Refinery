"""Two planning stages: which scene to label next, and which prompt to use.

Both read real artefacts and write real `evaluation` datasets. The *decision*
each makes is deliberately simple and the signal it uses is deliberately cheap,
because the point of building them now is the orchestration -- what reads what,
what gets recorded, what a later policy would consume. A better metric is a
change to one function, not to the pipeline.

Where a cheap proxy stands in for something expensive, it says so at the point
of substitution rather than in a note somewhere else.
"""

from iceberg.catalog.filesystem import FilesystemCatalog
from std.os.path import exists

from refinery.datasets import EvalRow, write_evaluation


def _split(line: String) -> List[String]:
    var out = List[String]()
    for part in line.split(","):
        out.append(String(part))
    return out^


def _column(header: List[String], name: String) -> Int:
    for i in range(len(header)):
        if header[i] == name:
            return i
    return -1


def _read_csv(path: String) raises -> Tuple[List[String], List[List[String]]]:
    var handle = open(path, "r")
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
            header = _split(line)
            first = False
            continue
        rows.append(_split(line))
    return (header^, rows^)


# ---------------------------------------------------------------- active learning


@fieldwise_init
struct SceneScore(Copyable, Movable):
    """How much a scene looks worth labelling."""

    var scene: String
    var tracks: Int
    var uncorroborated: Float64
    var mean_cls_conf: Float64

    def priority(self) -> Float64:
        """Higher means label this one first.

        Uncertainty about *names* is the signal available without touching the
        oracle: a track the detector could not corroborate, or named with low
        confidence, is one a person would resolve fastest. Deliberately not a
        model-uncertainty estimate -- that needs a model that reports one, and
        this needs to work on round zero when there is no model at all.
        """
        return self.uncorroborated + (1.0 - self.mean_cls_conf)


def score_scene(labels_path: String, scene: String) raises -> SceneScore:
    """Read a named-label CSV and measure how unresolved it is."""
    var head_rows = _read_csv(labels_path)
    ref header = head_rows[0]
    ref rows = head_rows[1]

    var c_track = _column(header, "track_id")
    var c_src = _column(header, "cls_source")
    var c_conf = _column(header, "cls_conf")

    var seen = List[String]()
    var unc = 0
    var total = 0
    var conf_sum = 0.0
    var conf_n = 0
    for i in range(len(rows)):
        ref r = rows[i]
        if c_track >= 0 and c_track < len(r):
            var tid = r[c_track]
            var known = False
            for k in range(len(seen)):
                if seen[k] == tid:
                    known = True
            if not known:
                seen.append(tid)
        total += 1
        if c_src >= 0 and c_src < len(r) and r[c_src] == "uncorroborated":
            unc += 1
        if c_conf >= 0 and c_conf < len(r) and r[c_conf].byte_length() > 0:
            conf_sum += Float64(r[c_conf])
            conf_n += 1

    var frac = 0.0 if total == 0 else Float64(unc) / Float64(total)
    var mean_conf = 0.0 if conf_n == 0 else conf_sum / Float64(conf_n)
    return SceneScore(scene, len(seen), frac, mean_conf)


def select_scene(
    labels_paths: List[String],
    scenes: List[String],
    warehouse: String,
    dataset_name: String,
    run_id: String,
    out_path: String,
    created_at: String = "",
) raises -> String:
    """Rank candidate scenes and record the ranking as an evaluation dataset.

    Returns the chosen scene. Every candidate's score is written, not just the
    winner -- a selection you cannot audit is indistinguishable from a coin
    toss, and the whole point of recording it is being able to ask later why
    this scene and not that one.
    """
    var scored = List[SceneScore]()
    for i in range(len(labels_paths)):
        if not exists(labels_paths[i]):
            continue
        scored.append(score_scene(labels_paths[i], scenes[i]))

    if len(scored) == 0:
        raise Error("no candidate label sets exist to select from")

    var rows = List[EvalRow]()
    var best = 0
    for i in range(len(scored)):
        ref sc = scored[i]
        rows.append(EvalRow(sc.scene, String("uncorroborated_fraction"), sc.uncorroborated))
        rows.append(EvalRow(sc.scene, String("mean_cls_conf"), sc.mean_cls_conf))
        rows.append(EvalRow(sc.scene, String("tracks"), Float64(sc.tracks)))
        rows.append(EvalRow(sc.scene, String("priority"), sc.priority()))
        if sc.priority() > scored[best].priority():
            best = i

    var catalog = FilesystemCatalog.local(warehouse)
    _ = write_evaluation(
        catalog,
        dataset_name,
        rows,
        String(""),
        String(""),
        String("select_scene"),
        run_id,
        created_at,
    )

    var chosen = scored[best].scene
    var out = open(out_path, "w")
    out.write("scene,priority,uncorroborated_fraction,mean_cls_conf,tracks\n")
    for i in range(len(scored)):
        ref sc = scored[i]
        out.write(
            sc.scene + "," + String(sc.priority()) + ","
            + String(sc.uncorroborated) + "," + String(sc.mean_cls_conf)
            + "," + String(sc.tracks) + "\n"
        )
    out.close()

    print(
        "select_scene:",
        len(scored),
        "candidates ->",
        chosen,
        "priority",
        scored[best].priority(),
    )
    return chosen^


# ------------------------------------------------------------ prompt optimization


def optimize_prompt(
    prompts_path: String,
    gold_path: String,
    warehouse: String,
    dataset_name: String,
    run_id: String,
    out_path: String,
    created_at: String = "",
) raises -> String:
    """Score each prompt set against the classes a gold set actually contains.

    The metric is **coverage**: what fraction of the gold classes this prompt's
    phrases can even express. A prompt that cannot name a class will never
    label it, so coverage is a ceiling on what the prompt could achieve, and it
    is computable from two CSVs without running a model.

    It is a ceiling, not a score. Whether the detector *finds* the thing it can
    name is the expensive question -- that means running Grounding DINO per
    prompt over the gold views, which belongs here and is not here yet. The
    dataset this writes has the shape that answer will need.
    """
    var ph = _read_csv(prompts_path)
    ref p_header = ph[0]
    ref p_rows = ph[1]
    var c_pid = _column(p_header, "prompt_id")
    var c_phrase = _column(p_header, "phrase")
    var c_maps = _column(p_header, "maps_to_class")
    if c_pid < 0 or c_maps < 0:
        raise Error("prompts CSV needs prompt_id and maps_to_class")

    var gd = _read_csv(gold_path)
    ref g_header = gd[0]
    ref g_rows = gd[1]
    var c_cls = _column(g_header, "cls")
    if c_cls < 0:
        raise Error("gold CSV has no cls column: " + gold_path)

    var gold_classes = List[String]()
    for i in range(len(g_rows)):
        if c_cls >= len(g_rows[i]):
            continue
        var cls = g_rows[i][c_cls]
        if cls.byte_length() == 0:
            continue
        var known = False
        for k in range(len(gold_classes)):
            if gold_classes[k] == cls:
                known = True
        if not known:
            gold_classes.append(cls)

    var ids = List[String]()
    for i in range(len(p_rows)):
        if c_pid >= len(p_rows[i]):
            continue
        var pid = p_rows[i][c_pid]
        var known = False
        for k in range(len(ids)):
            if ids[k] == pid:
                known = True
        if not known:
            ids.append(pid)

    var rows = List[EvalRow]()
    var best = String("")
    var best_cov = -1.0
    for i in range(len(ids)):
        var pid = ids[i]
        var covered = 0
        for g in range(len(gold_classes)):
            var hit = False
            for r in range(len(p_rows)):
                if c_pid >= len(p_rows[r]) or c_maps >= len(p_rows[r]):
                    continue
                if p_rows[r][c_pid] != pid:
                    continue
                # Either the ontology class or the raw phrase counts. The
                # phrase branch exists because `name_instances` writes the
                # detector's raw label into `cls` and never applies
                # `maps_to_class` -- so a gold set authored from its output
                # carries "haul truck", not "haul_truck". When the naming stage
                # applies the mapping, this branch becomes redundant rather
                # than wrong.
                if p_rows[r][c_maps] == gold_classes[g]:
                    hit = True
                if c_phrase >= 0 and c_phrase < len(p_rows[r]):
                    if p_rows[r][c_phrase] == gold_classes[g]:
                        hit = True
            if hit:
                covered += 1
        var phrases = 0
        for r in range(len(p_rows)):
            if c_pid < len(p_rows[r]) and p_rows[r][c_pid] == pid:
                phrases += 1
        var cov = 0.0 if len(gold_classes) == 0 else Float64(covered) / Float64(
            len(gold_classes)
        )
        rows.append(EvalRow(pid, String("class_coverage"), cov))
        rows.append(EvalRow(pid, String("phrases"), Float64(phrases)))
        if cov > best_cov:
            best_cov = cov
            best = pid

    var catalog = FilesystemCatalog.local(warehouse)
    _ = write_evaluation(
        catalog,
        dataset_name,
        rows,
        String(""),
        gold_path,
        String("optimize_prompt"),
        run_id,
        created_at,
    )

    var out = open(out_path, "w")
    out.write("prompt_id,class_coverage\n")
    for i in range(len(ids)):
        var pid = ids[i]
        for r in range(len(rows)):
            if rows[r].slice == pid and rows[r].metric == "class_coverage":
                out.write(pid + "," + String(rows[r].value) + "\n")
    out.close()

    print(
        "optimize_prompt:",
        len(ids),
        "prompts over",
        len(gold_classes),
        "gold classes -> best",
        best,
        "coverage",
        best_cov,
    )
    return best^
