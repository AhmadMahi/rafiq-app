import sys, re, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
lines = src.split("\n")

def grab(sig):
    """Pull one function verbatim, by brace balance from its signature line."""
    for i, l in enumerate(lines):
        if l.strip().startswith(sig):
            depth = 0; out = []
            for l2 in lines[i:]:
                out.append(l2)
                depth += l2.count("{") - l2.count("}")
                if depth == 0 and len(out) > 1:
                    return "\n".join(out)
    raise SystemExit("not found: " + sig)

want = ["private func find()", "private func note(", "func rescan()",
        "private func stopScanning()", "private func resweep()",
        "private func attach("]
body = "\n\n".join(grab(w) for w in want)
# startSweep's Timer needs a run loop we are not giving it; the harness
# calls resweep directly, so stub the scheduling out and keep the rest.
body = body.replace("startSweep()", "startSweepStub()")
# The harness's stand-in class is Link, not RobotLink; the bodies refer
# to their own type by name for the static UUIDs.
body = body.replace("RobotLink.", "Link.")
pathlib.Path(sys.argv[2]).write_text(body)
print("extracted", len(body), "bytes of the shipped bodies")
for w in want: print("  -", w)
