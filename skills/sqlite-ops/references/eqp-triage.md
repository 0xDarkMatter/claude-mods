# eqp-triage.py Invocations

Further `scripts/eqp-triage.py` invocations beyond the `--db` one in SKILL.md: triaging a plan captured elsewhere, and machine-readable output.

## More invocations

```bash
# Triage a plan captured elsewhere (D1, a log, a colleague's paste)
wrangler d1 execute atdw-mirror --remote --json \
  --command "EXPLAIN QUERY PLAN SELECT product_id FROM q_product WHERE org LIKE '%acme%'" \
  | python3 scripts/eqp-triage.py

# Machine-readable findings
python3 scripts/eqp-triage.py --db app.db --sql "SELECT ..." --json | jq '.data[]'
```
