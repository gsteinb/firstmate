# Acme Architecture
<!-- fm-arch:v1 -->

Acme is a peer-to-peer mortgage lending platform. Borrowers apply and are
automatically underwritten (a 3-gate engine); approved loans are listed on a
marketplace where KYC-approved investors fund them and receive scheduled
distributions. A separate admin portal handles review, compliance, and oversight.
A Go/Chi HTTP API over PostgreSQL is the core; three React 19 SPAs (borrower,
investor, admin) and async SQS workers surround it.

```text fm-diagram
        borrower SPA ─┐                 ┌─ Plaid ── Equifax ── Teranet AVM
        investor SPA ─┼─▶ Chi HTTP API ─┤
           admin SPA ─┘     (:8080)     └─ PostgreSQL (78 migrations)
                                │
                                ├─▶ SQS ─▶ email-worker ─▶ SES
                                └─▶ SQS ─▶ worker (deferred jobs)
```

## Backend API

> code: backend/main.go, backend/internal/, backend/cmd/

```text fm-diagram
 HTTP ─▶ Chi router ─▶ middleware ─▶ handler ─▶ service ─▶ store ─▶ Postgres
            (auth, CORS, rate-limit, security headers, 1MB body)
```

The Go/Chi server (`backend/main.go`, listens on `:8080`). Layered as
route → handler → service → store → DB. A middleware stack
(`internal/middleware/`) enforces auth, CORS, IP rate limits, security headers,
and a 1MB body cap. Cross-cutting services (DB pool, crypto for SIN/account-number
encryption, structured logging, SQS queue) live under `internal/`. Background
entry points in `backend/cmd/` (`worker`, `email-worker`, `admin-bootstrap`) run
out-of-band.

### Auth

> code: backend/internal/auth/, backend/internal/adminauth/, backend/internal/session/

```text fm-diagram
 /auth/*  ─▶ login ─▶ session ─▶ [2FA TOTP] ─▶ cookie
 /admin/auth/* ─▶ admin session ─▶ role gate (CCO/CEO/CTO)
```

Two independent session systems: borrower/investor auth (`internal/auth/`) and a
separate admin auth (`internal/adminauth/`) with role-based gates (CCO/CEO/CTO).
TOTP 2FA, password reset, and lockout are here; sessions and expired tokens are
swept by background jobs wired in `main.go`.

### Underwriting

> code: backend/internal/underwriting/, backend/internal/mortgagemath/

```text fm-diagram
 application ─▶ Gate1 (property ≤15) ─▶ Gate2 (stability ≤20) ─▶ Gate3 (verify ≤65)
                       │ hard stops              │ Equifax + AVM
                       ▼                         ▼
                   decline email           RiskGrade A/B/C/D/Ineligible ─▶ marketplace deal
```

The 3-gate scoring engine (`internal/underwriting/`). Gate 1 scores the property
(with hard stops), Gate 2 professional stability, Gate 3 verification (pulling
credit via `internal/equifax/` and valuation via the AVM stub). Output is a
RiskGrade plus an explainable per-gate breakdown; approvals create a marketplace
deal and offer, declines enqueue an email.

### Marketplace

> code: backend/internal/marketplace/

```text fm-diagram
 deal ─▶ reservation window ─▶ PlaceInvestment ─▶ {concentration cap, min check}
                                      │
                                      ▼
                          distribution waterfall ─▶ funded ─▶ arrears sweeper
```

Lists approved deals to KYC-approved investors and runs the funding engine
(`internal/marketplace/`). `PlaceInvestment` enforces concentration caps and
minimums (settings-driven), holds a soft reservation window against overbooking,
and computes the investor distribution waterfall.

## Frontends

> code: frontend/, frontend-admin/, frontend-shared/

```text fm-diagram
 frontend (borrower+investor SPA) ─┐
 frontend-admin (admin SPA) ───────┼─▶ api/client.ts ─▶ Chi API
 frontend-shared (@acme/shared) ────┘   envelope {success,message,data} · 401→/login
```

A pnpm monorepo of three React 19 + Vite apps. `frontend/` serves borrowers and
investors; `frontend-admin/` is the separate admin portal; `frontend-shared/`
(`@acme/shared`) holds the API response-envelope types and the `tokens.css`
design system both apps import.

### Admin portal

> code: frontend-admin/src/pages/, frontend-admin/src/components/

```text fm-diagram
 admin login(+TOTP) ─▶ dashboard ─▶ {borrowers, investors, deals} review
                                  └─▶ {audit log, complaints, STR, large-cash, disclosures}
```

The admin SPA (`frontend-admin/`) for oversight: KPI dashboard, borrower and
investor review, deal detail with a funding gate, the audit-log viewer, and the
compliance suite. Routes are guarded by `RoleProtectedRoute` against CCO/CEO/CTO
roles.

## Data & Infrastructure

This is a container node grouping the data and async infrastructure. (No diagram.)
