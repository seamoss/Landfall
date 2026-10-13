# 0007. Content-based filing with an LLM is an opt-in, bring-your-own-key add-on with fixed privacy limits

- **Status:** Accepted
- **Date:** 2026-10-13

## Context
Heuristics can recognise a transcript or a screenshot, but not that a PDF is a Globex offer letter or a bike manual. An LLM can, by reading the text. Sending file contents to a third party is a privacy decision the user must make, and API usage costs money the user should control.

## Decision
- **Smart Filing** is off by default and needs the user's own Anthropic API key (stored in the login keychain). There is no Landfall-operated service or billing.
- It calls the Messages API directly (no SDK exists for Swift) with JSON-schema structured output. Default model `claude-haiku-5-5`; Sonnet 5.5 and Opus 5.5 are selectable.
- **Scope:** only files Landfall isn't sure about, or every document with readable text. Firm rules (credentials, duplicates, archive twins, junk, installers, screenshots, captures, code, fonts, résumés, contacts) and the user's own rules always win.
- **What is sent:** name, type, size, download site, title, an excerpt of the text or OCR text (1,500 / 4,000 / 8,000 characters), the meeting title if any, library folder names, and client names, aliases and domains. **Never:** anything matching a credential or secret pattern, items flagged private (résumés, contact cards), or people's names from the client list. "Try on a File…" and `landfall ai --dry-run` show the exact payload.
- **Validation:** answers must name a library-relative folder without `..`, never `_Sensitive` or `Dev`. Confidence is capped at 0.8 (always a proposal) unless "may file on its own" is on, which allows up to 0.92.
- When it applies, the toast waits for the answer and marks it with ✦ and Claude's reason; filing uses the same answer. If Claude can't help, the rules' decision stands.
- Calls are counted per month in the ledger so the user can watch spend.

## Consequences
- Without a key, Landfall is fully functional and fully local.
- The prompt and schema are part of the privacy contract; changes to what is sent must update this record, the Settings copy and the README.
- Live calls aren't exercised by the test suite (it has no key); eligibility, validation, caps and payload shape are.
