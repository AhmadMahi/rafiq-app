"""Does every settings row leave room for its own label?

Row puts the title on the left and pins its content to the right at the
content's full ideal width. If the content is wide enough, the title
column is squeezed to nothing and SwiftUI wraps the label one character
per line. "OpenAI key" came out as four lines reading Op / en / AI /
key, under a note printed as a column of single letters.

Nothing errors. It compiles, it runs, and it looks like that.

The panel checker measures this properly but needs a window server and
produces nothing headless, so this is the cheap version: add up the
fixed widths a row's content asks for, and complain when what is left
cannot hold the title.
"""
import re, sys, os, glob

PANEL = 330          # Panel.width
PAD = 11 * 2         # SettingsPane's padding
SCROLL = 8
GAP = 10             # Row's Spacer(minLength:)
CH = 6.6             # a character of .system(size: 12), near enough
BUTTON = 22          # Button padding either side of its text
USABLE = PANEL - PAD - SCROLL

def content_width(block):
    """What the trailing content will ask for.

    A Picker with a .frame(width:) is that width, whatever its options
    say, so its options are taken out before anything is counted or they
    are counted twice and every picker row looks broken.
    """
    block = re.sub(r"Picker\(.*?\)\s*\{.*?\n\s*\}", "PICKER", block, flags=re.S)
    block = re.sub(r"ForEach\(.*?\)\s*\{.*?\}", "", block, flags=re.S)
    w = 0.0
    for m in re.finditer(r"\.frame\(\s*(?:min)?[Ww]idth:\s*(\d+)", block):
        w += float(m.group(1))
    for m in re.finditer(r'Button\("([^"]*)"', block):
        w += len(m.group(1)) * 6.0 + BUTTON
    for m in re.finditer(r'Text\("([^"]*)"\)', block):
        w += len(m.group(1)) * 6.0
    # a TextField with no frame still wants room for its placeholder
    for m in re.finditer(r'(?:TextField|SecureField)\(\s*"([^"]*)"', block):
        if ".frame(" not in block.split(m.group(0))[-1][:120]:
            w += max(60.0, len(m.group(1)) * 6.0)
    for m in re.finditer(r"spacing:\s*(\d+)", block):
        w += float(m.group(1))
    return w

problems = []
checked = 0
for path in sorted(glob.glob("Sources/*.swift")):
    src = open(path).read()
    for m in re.finditer(r'Row\(title:\s*"([^"]*)"', src):
        title = m.group(1)
        # the block is from here to the matching close of the trailing closure
        i = src.index("{", m.end())
        depth = 0
        for j in range(i, min(len(src), i + 2600)):
            if src[j] == "{": depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0: break
        block = src[i:j + 1]
        checked += 1
        cw = content_width(block)
        left = USABLE - cw - GAP
        need = len(title) * CH
        if left < need:
            problems.append(
                f"{os.path.basename(path)}: \"{title}\" needs {need:.0f}pt, "
                f"content takes {cw:.0f}pt, {left:.0f}pt left")

print()
print(f"  {checked} rows checked, {USABLE}pt usable")
for p in problems: print("  FAIL", p)
print()
if problems:
    print("  Put a wide control on its own line instead of beside the label.")
    sys.exit(1)
print("PASS: every row leaves room for its label")
