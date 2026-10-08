"""Number formatting shared by the ledger modules."""


def format_number(value):
    """Thousands separators and at most two decimals; trailing zeros are dropped.

    format_number(1234.5) == "1,234.5" and format_number(1000) == "1,000".
    """
    text = "{:,.2f}".format(value)
    text = text.rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text
