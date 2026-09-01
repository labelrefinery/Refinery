"""Which stage runs next.

Today this picks at random, which is the point: the plumbing that records a
decision, acts on it, and shows it on the timeline is what needs proving first.
A model implementing `choose` later changes what gets picked and nothing else.

Random does not mean arbitrary. A pick is made only from *legal* stages -- ones
whose inputs are all present and whose outputs are not -- so a random choice is
still a runnable one, and the run makes progress rather than failing on a stage
whose inputs do not exist yet.
"""

from std.os.path import exists
from std.random import random_ui64

from refinery.steps import Stage


@fieldwise_init
struct Decision(Copyable, Movable):
    """What the router chose, and what it was choosing between."""

    var chosen: Int
    """Index into the stage list. -1 when nothing is legal: the run is done."""
    var candidates: List[String]
    var reason: String
    var model: String

    def candidates_json(self) -> String:
        var out = String("[")
        for i in range(len(self.candidates)):
            if i > 0:
                out += ", "
            out += '"' + self.candidates[i] + '"'
        out += "]"
        return out^

    def is_done(self) -> Bool:
        return self.chosen < 0


def inputs_ready(stage: Stage) raises -> Bool:
    """Every declared input exists."""
    for path in stage.inputs:
        if not exists(String(path)):
            return False
    return True


def is_legal(stage: Stage, satisfied: Bool) raises -> Bool:
    """Runnable: inputs are present and the work is not already done.

    `satisfied` comes from the ledger, not from whether the outputs happen to
    exist. Those are different questions, and the difference is the whole point
    of hashing content: a stage whose outputs exist but whose *inputs changed*
    is not done, and must run again. Deciding legality on output existence
    alone would make that stage permanently ineligible and silently serve stale
    results for the rest of the run.
    """
    if not inputs_ready(stage):
        return False
    return not satisfied


def legal_stages(stages: List[Stage], satisfied: List[Bool]) raises -> List[Int]:
    var out = List[Int]()
    for i in range(len(stages)):
        if is_legal(stages[i], satisfied[i]):
            out.append(i)
    return out^


def choose_random(
    stages: List[Stage], satisfied: List[Bool]
) raises -> Decision:
    """Pick uniformly from the legal stages."""
    var legal = legal_stages(stages, satisfied)
    var names = List[String]()
    for i in legal:
        names.append(stages[Int(i)].name)

    if len(legal) == 0:
        return Decision(-1, names^, String("nothing is runnable"), String("random"))

    var pick = Int(random_ui64(0, UInt64(len(legal) - 1)))
    var index = legal[pick]
    return Decision(
        index,
        names^,
        String("uniform over ") + String(len(legal)) + " legal stages",
        String("random"),
    )
