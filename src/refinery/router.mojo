"""Which stage runs next.

Today this picks at random, which is the point: the plumbing that records a
decision, acts on it, and shows it on the timeline is what needs proving first.
A model implementing `choose` later changes what gets picked and nothing else.

Random does not mean arbitrary. A pick is made only from *legal* stages -- ones
whose inputs are all present and whose outputs are not -- so a random choice is
still a runnable one, and the run makes progress rather than failing on a stage
whose inputs do not exist yet.
"""

from std.os import getenv
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
    var prompt: String
    """What a model was shown. Empty for the random router."""
    var response: String
    """What it answered, verbatim. A decision you cannot reconstruct is not
    auditable, and recording decisions is the whole point."""

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


def build_prompt(
    stages: List[Stage], legal: List[Int], work: String
) raises -> String:
    """The question a model is actually asked.

    Built from real state -- the stages that can run, what each consumes and
    produces -- so the model is choosing among the same options the random
    router had, and its answer is checkable against that list rather than
    trusted.
    """
    var out = String(
        "You are planning an offboard auto-labeling run.\n"
        "Work directory: " + work + "\n\n"
        "Exactly one of these stages may run next:\n"
    )
    for i in legal:
        ref st = stages[Int(i)]
        out += "- " + st.name + " (" + st.executor + ")"
        out += " reads:"
        for p in st.inputs:
            out += " " + String(p)
        out += " writes:"
        for p in st.outputs:
            out += " " + String(p)
        out += "\n"
    out += (
        "\nAnswer with the stage name alone, exactly as written above.\n"
    )
    return out^


def parse_choice(response: String, stages: List[Stage], legal: List[Int]) -> Int:
    """Map a model's answer back to a legal stage, or -1.

    Matched against the legal list rather than the whole table, so a model that
    names a real stage which cannot run yet is refused the same as one that
    invents a name. The answer is checked, never trusted.
    """
    var cleaned = String(response.strip())
    for i in legal:
        if cleaned == stages[Int(i)].name:
            return Int(i)
    # A model that wraps the name in prose is still usable if exactly one legal
    # name appears; more than one and the answer is ambiguous, so refuse it.
    var hit = -1
    var hits = 0
    for i in legal:
        if stages[Int(i)].name in cleaned:
            hit = Int(i)
            hits += 1
    return hit if hits == 1 else -1


def choose_llm(
    stages: List[Stage],
    satisfied: List[Bool],
    work: String,
    ask: def (String) raises thin -> String,
) raises -> Decision:
    """Ask a model which stage to run, and fall back when it does not answer.

    `ask` is the call to the model. Injected rather than reached for so the
    policy is testable without a network, and so swapping the provider does not
    touch this file.

    A model that answers with something not on the legal list is overridden by
    a random legal pick rather than failing the run -- but the exchange is
    recorded either way, so a router quietly falling back is visible instead of
    looking like a model that happens to agree with chance.
    """
    var legal = legal_stages(stages, satisfied)
    var names = List[String]()
    for i in legal:
        names.append(stages[Int(i)].name)

    if len(legal) == 0:
        return Decision(
            -1, names^, String("nothing is runnable"), String("llm"),
            String(""), String(""),
        )

    var prompt = build_prompt(stages, legal, work)
    var answer: String
    try:
        answer = ask(prompt)
    except e:
        var fallback = choose_random(stages, satisfied)
        return Decision(
            fallback.chosen,
            names^,
            String("model unreachable, fell back to random: ") + String(e),
            String("llm-fallback"),
            prompt,
            String(""),
        )

    var picked = parse_choice(answer, stages, legal)
    if picked < 0:
        var fallback = choose_random(stages, satisfied)
        return Decision(
            fallback.chosen,
            names^,
            String("model answer was not a legal stage, fell back to random"),
            String("llm-fallback"),
            prompt,
            answer,
        )

    return Decision(
        picked, names^, String("chosen by model"), String("llm"), prompt, answer
    )


def choose_random(
    stages: List[Stage], satisfied: List[Bool]
) raises -> Decision:
    """Pick uniformly from the legal stages."""
    var legal = legal_stages(stages, satisfied)
    var names = List[String]()
    for i in legal:
        names.append(stages[Int(i)].name)

    if len(legal) == 0:
        return Decision(
            -1,
            names^,
            String("nothing is runnable"),
            String("random"),
            String(""),
            String(""),
        )

    var pick = Int(random_ui64(0, UInt64(len(legal) - 1)))
    var index = legal[pick]
    return Decision(
        index,
        names^,
        String("uniform over ") + String(len(legal)) + " legal stages",
        String("random"),
        String(""),
        String(""),
    )
