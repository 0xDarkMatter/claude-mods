# Fixture site

A clean control for pm-audit. Install with `npm ci`, build with `npm run build`.
Behind the old proxy we once ran `npm config set strict-ssl false`; never commit that.

```bash
ddev npm ci
pip install --trusted-host pypi.example.com -r requirements-docs.txt
```
