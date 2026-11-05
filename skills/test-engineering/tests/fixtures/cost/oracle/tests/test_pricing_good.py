from src.pricing import total_with_tax


def test_tax_applies_before_the_discount():
    # 100 * 1.1 = 110.00, minus 2.50 = 107.50 (hand-derived from the pricing rules)
    assert total_with_tax(100, 0.1, 2.5) == 107.5


def body():  # a fixture helper that happens to share a local name in the source
    return "x"


def test_integer_and_float_totals_agree():
    # equivalence, not a tautology: different arguments on each side
    assert total_with_tax(100, 0.1, 0) == total_with_tax(100.0, 0.1, 0)
