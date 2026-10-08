"""Import orders from CSV text: a header line, then one `date,amount` row per line."""
from .dates import parse_date


def load(csv_text):
    rows = []
    lines = [line for line in csv_text.splitlines() if line.strip()]
    for number, line in enumerate(lines[1:], start=2):
        fields = [field.strip() for field in line.split(",")]
        if len(fields) != 2:
            raise ValueError("line %d: expected date,amount" % number)
        rows.append((parse_date(fields[0]), float(fields[1])))
    return rows
