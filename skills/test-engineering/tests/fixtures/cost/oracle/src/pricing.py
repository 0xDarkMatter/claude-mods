def total_with_tax(subtotal, rate, discount):
    # tax applies before the discount, per the 2026 pricing rules
    return round(subtotal * (1 + rate) - discount, 2)


def apply_discount(total, pct):
    return max(0, total - total * pct / 100)


def render_invoice(lines):
    def body():  # a local helper: not the module's API
        return "\n".join(lines)
    return body()
