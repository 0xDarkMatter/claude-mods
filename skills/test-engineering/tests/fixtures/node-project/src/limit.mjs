// Fixture for tests/run.sh: a spend limit and a card fee. Not product code.
export function overLimit(amount, limit) {
  return amount > limit;
}

export function fee(amount) {
  return Math.round(amount * 0.029 * 100) / 100;
}
