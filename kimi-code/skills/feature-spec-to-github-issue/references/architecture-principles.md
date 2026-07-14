# Architecture Principles for Feature Specs

## Single Source of Truth

When a computation (Greeks, pricing, risk scores, enrichment) is needed in multiple places, extract it into a standalone module.

**Bad:**
- Portfolio view endpoint computes fallback inline
- Screener computes fallback inline
- Frontend component computes fallback inline

**Good:**
- `core/pricing/greek_enrichment.py` provides `enrich_contract_greeks()`
- Both portfolio view and screener call the same function
- Frontend receives a `_synthetic_greeks` flag and adjusts UI accordingly

## Progressive Enrichment Pattern

```
Raw Provider Data → Enrichment Layer → Enriched Data → Consumers
```

The enrichment layer:
1. Checks if live data is complete
2. Computes synthetic values only for missing fields
3. Adds metadata flags (`_synthetic_*`) 
4. Never overwrites provider data when present

## Consumer-Layer Enrichment

Keep provider classes thin. The provider returns exactly what the API returns. Enrichment happens in the service/endpoint layer where the consumer has:
- Context about what downstream needs
- Access to cross-cutting data (underlying prices, historical vol, etc.)
- Ability to add domain-specific metadata flags

## Self-Documenting Synthetic Data

Always add a boolean flag so downstream can distinguish:

```python
enriched[key] = {**data, **greeks, "_synthetic_greeks": True}
```

Frontend/tooltips should adjust:
- Live: "Live delta = -0.505"
- Synthetic: "Computed delta = -1.0 (synthetic — provider did not provide Greeks)"

## Testable Units

Enrichment functions should be pure:
- Inputs: contract data + market data
- Outputs: enriched contract data
- No DB calls, no API calls, no side effects

This enables unit tests with hardcoded inputs/outputs.
