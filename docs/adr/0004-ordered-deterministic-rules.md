# 0004. Classification is an ordered list of deterministic handlers; firm rules first

- **Status:** Accepted
- **Date:** 2026-10-12

## Context
Most arrivals are recognisable from cheap facts: extension, name patterns, a Tactiq header, the quarantine flag, a hash. Explaining *why* something moved matters as much as moving it, and some decisions are safety-critical (credentials) and must not be overridden.

## Decision
`Classifier.classify` runs handlers in a fixed order and takes the first answer:
ignore → credential → your rules → duplicate → archive twin → junk → installer → code → meeting transcript → stale localhost capture → screenshot → font → résumé → contact → 3D/CAD → contract → media → client match → image → hold.

Each handler returns a `Decision` with an action, destination, confidence, rule name and a human reason. Context that isn't in the file (calendar meetings, OCR text) is gathered first and fed in as facts. Rename suggestions and per-folder placement (0005) are applied after the handler decides.

## Consequences
- Credentials are recognised before anything else, including your own rules.
- Every decision is explainable (`landfall why`) and testable with fixtures.
- New behaviour is a new handler in the right position, with tests. Content understanding beyond these heuristics is Smart Filing's job (0007), and it runs after firm rules, never instead of them.
