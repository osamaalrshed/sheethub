# SheetsHub — Customizations Reference

This file lists every non-default change made to NocoDB, what each does,
and how to maintain it across NocoDB version upgrades.

> NocoDB version pinned to **2026.05.0**. See [Update strategy](#update-strategy)
> at the bottom for when (and when not) to upgrade.

## URL

| URL | Who | UI |
|---|---|---|
| `http://<host>:8080` (or your `NC_PUBLIC_URL`) | Everyone | Restricted by default; admin sees full UI automatically |

**How the same URL serves two experiences:**

nginx injects two assets into every NocoDB page:
- `nocodb-custom.css` — CSS hides, all scoped to `body:not(.is-admin)`
- `nocodb-admin-detector.js` — runs once per page load, calls `/api/v1/auth/user/me`,
  and if the logged-in user matches an admin email, adds `is-admin` to `<body>`
  (which disables every hide rule)

Admin emails are listed in `nginx/admin-detector.js` (`ADMIN_EMAILS = [...]`).
Edit and restart nginx (`docker compose restart nginx`) to add more admins.
Keep this list in sync with `NC_ADMIN_EMAIL` in `.env` for the default admin.

**Trade-off:** Admin sees a brief flash (~100 ms) of the restricted UI on each page load
before the detector finishes and the CSS unhides everything. Acceptable for the simpler
"one URL for everyone" setup.

## What's hidden on port 8181 (business view)

See `nginx/custom.css` for the actual selectors. Categories:

### Mini left rail
- Workflows, Settings, Activity, Help icons (`[data-panel="..."]`)
- "+" plus button (`.nc-mini-sidebar-plus-btn`)
- "Try NocoDB Cloud" promo + version label (`.nc-sidebar-bottom-section`)

### Top bar
- Share button (`[data-testid="share-base-button"]`)
- History/audit button (`[data-testid="nc-topbar-history-btn"]`)
- Extension button (`[data-testid="nc-topbar-extension-btn"]`)
- Details tab (matched by SVG `stroke="transparent"`)

### Table toolbar
- Group button (`.nc-group-by-menu-btn`)
- Colour button (`.nc-coloring-menu-btn`)

### Column header dropdown
- Edit field, Duplicate field, Edit description
- Edit field permissions (Business tier)
- Insert right, Insert left, Delete field
- Group by this field
- (Kept: Hide field, Sort, Filter, Set as display value)

### Schema editing
- The full "Add / Edit field" dialog form (`[data-testid="add-or-edit-column"]`)
- "+ Add column" buttons in grid header

### Sidebar
- "Create new" base/table button (`[data-testid="nc-home-create-new-btn"]`)
- Drag handles to reorder tables (`[data-testid^="tree-view-table-draggable-handle-"]`)
- Create-view button on each table (`[data-testid="nc-sidebar-table-create-view-btn"]`)
- "Untitled" doc placeholder entries

### User profile menu
- Hidden: Log Out, Experimental Features, Keyboard Shortcuts, API Tokens, Account Settings, Admin Panel
- Kept: Appearance (dark/light), Language

## Beyond CSS — other customizations

### Public sharing
- `NC_DISABLE_SHARING=true` env var (does not work in 2026.05.0 — kept for future)
- nginx returns 403 for any `/nc/view/*` URL → blocks public share links at network level

### Upload limits
- nginx `client_max_body_size 50m`
- `NC_ATTACHMENT_FIELD_SIZE` and `NC_REQUEST_BODY_SIZE` env vars set to 50 MB

### URL construction
- `NC_PUBLIC_URL` set in `.env` so NocoDB generates correct absolute URLs (file
  downloads, share links). **Update this when deploying to a server.**

### Network
- Docker subnet pinned to `100.64.0.0/24` to avoid private IP ranges NocoDB's SSRF
  protection blocks
- `NC_ALLOW_LOCAL_EXTERNAL_DBS=true` to let NocoDB connect to the postgres container

### Database
- `audit` schema in `business_inputs`:
  - `audit.change_log` — every INSERT/UPDATE/DELETE on finance/sales/operations
  - Triggered automatically by `audit.log_change()` (SECURITY DEFINER)
- `analytics` schema (created by `05-analytics-schema.sql`):
  - Mirror tables + `_sync_cursor` used by the optional `realtime-sync` dev service
- PostgreSQL auth: default `scram-sha-256` works; switch to `md5` only if a
  legacy client doesn't support SCRAM (we did this for an older DBeaver build)

## Sync services

| Service | Where it runs | Frequency | Pattern |
|---|---|---|---|
| **sync** (production) | `sheetshub-sync` container | every 30 min | Incremental CDC: appends each audit-log change to ClickHouse with `_version` + `_deleted`. `ReplacingMergeTree(_version)` deduplicates on merge. |
| **realtime-sync** (dev) | `sheetshub-realtime-sync` (only via `docker-compose.dev.yml`) | every 2 s | Postgres → Postgres incremental replay of audit log for the analytics schema |

Both read from `audit.change_log` to determine what changed.

ClickHouse queries should filter `_deleted = 0` and use `FINAL` (or
`argMax(_version)`) to see the current row state. The sync service never
issues `UPDATE` or `DELETE` against ClickHouse — append-only writes only.

Each ClickHouse table has its own hand-crafted DDL under
`sync-service/clickhouse_schemas/`. Engineers edit those files to tune
`ORDER BY` / `PARTITION BY` for analytics access patterns. Adding a new
table: add a DDL file + entry in `config.yaml`. See
`sync-service/README.md` for the playbook.

## Roles in use

| Role | Where set | Who has it | What they can do |
|---|---|---|---|
| `owner` | `nc_base_users_v2.roles` | `admin@sheetshub.local` | Full UI (via JS admin detector) |
| `creator` | `nc_base_users_v2.roles` | Users who need CSV upload | Editor + Upload CSV via UI |
| `editor` | `nc_base_users_v2.roles` | Most business users | Read/edit rows, paste from Excel |

To promote a user from editor → creator:

```sql
UPDATE nc_base_users_v2 SET roles = 'creator' WHERE fk_user_id = (
  SELECT id FROM nc_users_v2 WHERE email = 'finance@test.local'
);
```

## Recovering deleted data

The audit log captures every row delete. To restore:

```sql
INSERT INTO finance.cost_centers
SELECT * FROM jsonb_populate_recordset(NULL::finance.cost_centers,
  (SELECT jsonb_agg(old_data) FROM audit.change_log
   WHERE table_schema='finance' AND table_name='cost_centers'
     AND action='D' AND changed_at > '2026-05-12 14:00'));
```

## Update strategy

**Stay on `2026.05.0` until there's a real reason to update.**

Update only when:
- A security advisory affects your version
- A bug fix solves an actual problem you're experiencing
- You need a feature that doesn't exist in 2026.05.0

Skip everything else (cosmetic, performance, new integrations).

### Update procedure

1. **Test in a separate environment first**:
   ```powershell
   # Edit docker-compose.yml — change tag to new version
   # Use different project name so it doesn't collide
   docker compose -p nocodb-test up -d
   ```

2. **Verify each hidden element is still hidden** at `http://localhost:NEW_PORT`:
   - Walk through the categories above; if anything reappears, the CSS selector broke
   - Update the selector in `nginx/custom.css`

3. **Test the audit triggers still fire**:
   ```sql
   UPDATE finance.cost_centers SET name = name WHERE code = (SELECT code FROM finance.cost_centers LIMIT 1);
   SELECT * FROM audit.change_log ORDER BY id DESC LIMIT 1;
   ```

4. **Verify export URLs still include the port** (regression check for NC_PUBLIC_URL)

5. Only then update production by changing the tag in the main `docker-compose.yml`

### Realistic maintenance frequency

If you follow "security only" updates: roughly **1-2 NocoDB updates per year**, ~30 min each to verify customizations.

## What's NOT customized

These are the things that work out of the box without modification:
- NocoDB's own audit log on each row (visible when expanding a row)
- Excel-style paste from clipboard (works at Editor level)
- All the data-editing features (sort, filter, search, comments, etc.)
- NocoDB's built-in PostgreSQL connection
