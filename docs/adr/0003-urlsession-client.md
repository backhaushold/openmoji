# ADR-0003: Plain URLSession async client, no SDK

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
The app makes two OpenAI calls (`POST /v1/images/generations`, `GET /v1/models/{id}`). NFR-7 forbids third-party SDKs. There is no official OpenAI Swift SDK; community packages add dependency and supply-chain surface inside a process that holds an API key.

## Decision
A ~150-line `OpenAIClient` actor in OpenMojiCore on `URLSession` with `async`/`await`:
- `URLSessionConfiguration.ephemeral`, so prompts and images are never cached to disk.
- 90 s request and resource timeouts (NFR-4).
- No automatic retries (each attempt costs money; D3, D7).
- `Codable` request and response types limited to the fields we use.
- Errors decoded from `{"error":{message,type,code,param}}` and handed to `ErrorMapper`.

## Alternatives
- **Community OpenAI Swift package.** Faster to start, but it's a dependency, violates NFR-7, and lags API changes such as new 429 codes.
- **Alamofire or other HTTP libraries.** No benefit for two endpoints.

## Consequences
- Zero package dependencies; `Package.resolved` stays empty.
- We own the wire format: API changes need a code change, mitigated by FR-9 configuration and by tests on canned responses.
