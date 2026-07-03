# Linkboard Architecture
<!-- fm-arch:v1 -->

Linkboard is a link-aggregation and discussion-forum platform. Members submit
links and text posts to topic boards, comment in threads, and vote; a ranking
engine builds the popular and personalized feeds, and full-text search covers
posts and comments. A Go HTTP API gateway over PostgreSQL is the core; a React
19 SPA, a separate moderator portal, and async queue workers (search indexing,
notifications) surround it, with Redis caching hot feeds and sessions.

```text fm-diagram
         web SPA ─┐                  ┌─ Redis (feeds, sessions)
      mobile app ─┼─▶ API gateway ───┼─ OpenSearch (full-text)
   embed widgets ─┘     (:8080)      └─ PostgreSQL (54 migrations)
                          │
                          ├─▶ queue ─▶ index-worker ─▶ OpenSearch
                          └─▶ queue ─▶ notify-worker ─▶ email + push
```

## Backend API

> code: backend/main.go, backend/internal/, backend/cmd/

```text fm-diagram
 HTTP ─▶ router ─▶ middleware ─▶ handler ─▶ service ─▶ store ─▶ Postgres
           (auth, CORS, rate-limit, security headers, 1MB body)
```

The Go API gateway (`backend/main.go`, listens on `:8080`). Layered as
route → handler → service → store → DB. A middleware stack
(`internal/middleware/`) enforces auth, CORS, IP rate limits, security headers,
and a 1MB body cap. Cross-cutting services (DB pool, Redis cache client,
structured logging, queue producer) live under `internal/`. Background entry
points in `backend/cmd/` (`index-worker`, `notify-worker`, `admin-bootstrap`)
run out-of-band.

### Auth

> code: backend/internal/auth/, backend/internal/modauth/, backend/internal/session/

```text fm-diagram
 /auth/*  ─▶ login ─▶ session ─▶ [2FA TOTP] ─▶ cookie
 /mod/auth/* ─▶ moderator session ─▶ role gate (mod/admin)
```

Two independent session systems: member auth (`internal/auth/`) and a separate
moderator auth (`internal/modauth/`) with role-based gates (mod/admin). TOTP
2FA, password reset, and lockout are here; sessions and expired tokens are
swept by background jobs wired in `main.go`.

### Posts & Votes

> code: backend/internal/posts/, backend/internal/votes/

```text fm-diagram
 submit ─▶ spam + rate checks ─▶ post ─▶ comment tree ─▶ votes
                 │                                          │
                 ▼                                          ▼
          moderation queue                    score events ─▶ ranking
```

The content core (`internal/posts/`, `internal/votes/`). Submissions pass spam
and rate checks, comments form a threaded tree, and votes are idempotent per
member, publishing score-change events to the queue for the ranking engine;
flagged content lands in the moderation queue.

### Feed & Ranking

> code: backend/internal/feed/, backend/internal/ranking/

```text fm-diagram
 score events ─▶ ranking (hot/top/new) ─▶ feed builder ─▶ Redis feed cache
                                               │
                                               ▼
                                  home + board feeds (cursor paging)
```

Builds the popular and personalized feeds (`internal/feed/`,
`internal/ranking/`). Hot, top, and new scores are recomputed from vote
events, the feed builder materializes per-board and home feeds into the Redis
cache, and the API serves them with cursor paging.

## Frontends

> code: frontend/, frontend-mod/, frontend-shared/

```text fm-diagram
 frontend (member SPA) ───────────────┐
 frontend-mod (mod SPA) ──────────────┼─▶ api/client.ts ─▶ API gateway
 frontend-shared (@linkboard/shared) ─┘   envelope {success,message,data} · 401→/login
```

A pnpm monorepo of three React 19 + Vite apps. `frontend/` serves members;
`frontend-mod/` is the separate moderator portal; `frontend-shared/`
(`@linkboard/shared`) holds the API response-envelope types and the
`tokens.css` design system both apps import.

### Moderator portal

> code: frontend-mod/src/pages/, frontend-mod/src/components/

```text fm-diagram
 mod login(+TOTP) ─▶ dashboard ─▶ {reports, spam, appeals} review
                               └─▶ {audit log, board settings, member actions}
```

The moderator SPA (`frontend-mod/`) for oversight: the report queue, spam
review, appeals, the audit-log viewer, and board settings. Routes are guarded
by `RoleProtectedRoute` against mod/admin roles.

## Data & Infrastructure

This is a container node grouping the data and async infrastructure:
PostgreSQL as the system of record, Redis for feed and session caching,
OpenSearch for full-text search, and the queue-driven `index-worker` and
`notify-worker`. (No diagram.)
