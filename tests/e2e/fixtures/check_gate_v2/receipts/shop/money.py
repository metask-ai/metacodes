"""Money helpers. All amounts are integer cents."""


def format_cents(cents):
    """Format cents as a decimal string: 12345 -> '123.45', -150 -> '-1.50'."""
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return "%s%d.%02d" % (sign, cents // 100, cents % 100)


def parse_amount(text):
    """Parse '12.34', '12.3', '12' or '-1.50' into cents."""
    text = text.strip()
    negative = text.startswith("-")
    if negative:
        text = text[1:]
    whole, _, frac = text.partition(".")
    if not whole.isdigit() or (frac and (not frac.isdigit() or len(frac) > 2)):
        raise ValueError("not an amount: %r" % text)
    cents = int(whole) * 100 + int((frac + "00")[:2])
    return -cents if negative else cents


def round_half_up(numerator, denominator):
    """numerator / denominator rounded to the nearest integer, halves away from zero."""
    quotient, remainder = divmod(abs(numerator), denominator)
    if 2 * remainder >= denominator:
        quotient += 1
    return quotient if numerator >= 0 else -quotient
