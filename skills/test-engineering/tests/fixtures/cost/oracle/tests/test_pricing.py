from src.pricing import total_with_tax


def test_copies_the_formula():
    subtotal, rate, discount = 100, 0.1, 2.5
    expected = round(subtotal * (1 + rate) - discount, 2)
    assert total_with_tax(subtotal, rate, discount) == expected


def apply_discount(total, pct):
    return max(0, total - total * pct / 100)


def test_shadow_copy():
    assert apply_discount(50, 10) == 45


def test_self_oracle():
    assert total_with_tax(100, 0.1, 0) == total_with_tax(100, 0.1, 0)


def test_pastes_the_formula_into_the_assertion(subtotal=100, rate=0.1, discount=2.5):
    assert total_with_tax(subtotal, rate, discount) == round(subtotal * (1 + rate) - discount, 2)
