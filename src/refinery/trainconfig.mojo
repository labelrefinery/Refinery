"""Write a CenterPillars training config from the checked-in template.

A port of the substitution in `steps.train_student`, which rewrites exactly
three lines of `configs/sitegen.yaml`: the data root, the run name and the
epoch count. Everything else -- pillar size, ranges, learning rate, the class
list -- comes from the template unchanged, so a config in a run directory is
the template plus the three things that vary per run.

The matching is by line prefix, exactly as the Python did, which means it is
sensitive to the template's indentation. That fragility is inherited
deliberately rather than fixed: changing it here without changing the template
would make the two silently disagree about what a config looks like. There is
a test that fails if a key goes missing.
"""


@fieldwise_init
struct ConfigMetrics(Copyable, ImplicitlyCopyable, Movable):
    var lines: Int
    var substituted: Int

    def as_json(self) -> String:
        return String(
            '{"lines": ', self.lines, ', "substituted": ', self.substituted, "}"
        )


def write_train_config(
    template_path: String,
    out_path: String,
    data_root: String,
    run_name: String,
    epochs: Int,
) raises -> ConfigMetrics:
    """Rewrite the three per-run lines and leave the rest of the template alone."""
    var handle = open(template_path, "r")
    var text = handle.read()
    handle.close()

    var out = String("")
    var count = 0
    var substituted = 0
    for raw in text.split("\n"):
        var line = String(raw)
        if count > 0:
            out += "\n"
        count += 1
        if line.startswith("  root:"):
            out += "  root: " + data_root
            substituted += 1
        elif line.startswith("run_name:"):
            out += "run_name: " + run_name
            substituted += 1
        elif line.startswith("  epochs:"):
            out += "  epochs: " + String(epochs)
            substituted += 1
        else:
            out += line

    if substituted < 3:
        raise Error(
            "template is missing one of root/run_name/epochs (matched "
            + String(substituted)
            + " of 3): "
            + template_path
        )

    var w = open(out_path, "w")
    w.write(out + "\n")
    w.close()

    print("config:", out_path, "run_name", run_name, "epochs", epochs)
    return ConfigMetrics(count, substituted)
