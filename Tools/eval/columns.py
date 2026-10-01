"""usage: <benchmark output> | columns.py <column> [<column> ...] — prints the setting name and the named columns of a
benchmark table (e.g. `columns.py trace "rc trace" "GPU total"`)."""
import re, sys

want = sys.argv[1:]
header = None
for line in sys.stdin:
    cells = re.split(r" {2,}", line.strip())
    if cells and cells[0] == "setting":
        header = cells
        print(f"{'setting':28s}" + "".join(f"{c[:12]:>13s}" for c in want if c in header))
    elif header and len(cells) == len(header) and not line.startswith("-"):
        print(f"{cells[0]:28s}" + "".join(f"{cells[header.index(c)]:>13s}" for c in want if c in header))
