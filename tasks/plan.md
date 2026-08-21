# Implementation Plan: Simplified Electronics Inventory Profile

## Overview

Configure the Iranian InvenTree distribution for the requested electronics
inventory workflow while retaining only parts, categories, stock, BOMs, builds,
purchasing, pricing, plugins, audit history, backups, and role-based access.

## Architecture Decisions

- Use global settings to disable optional workflows without deleting data.
- Use a least-privilege warehouse group for the daily interface; keep `root`
  only for administration because superusers always see every module.
- Customize the imported training `engineer` account instead of embedding a new
  password in the installer.
- Document the exact workflow rather than changing core inventory semantics.

## Task List

### Phase 1: Requirement mapping

- [x] Map every requested behavior to the existing InvenTree feature or plugin.
- [x] Identify required roles and optional global settings.

### Phase 2: Minimal profile

- [x] Add the minimal global setting overrides to installer defaults.
- [x] Provision a restricted training warehouse group idempotently.
- [x] Apply the same profile to the running port-8000 learning instance.

### Checkpoint: Minimal profile

- [x] Parts, stock, manufacturing, purchasing, plugins, and backups remain active.
- [x] Sales, returns, transfers, barcode, labels, reports, machines, and projects are disabled or inaccessible to the warehouse user.

### Phase 3: Verification and guide

- [x] Verify the restricted user interface in an isolated browser.
- [x] Verify role permissions, background worker, plugins, and automatic backup settings.
- [x] Write the Persian end-user guide for all required workflows.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Hiding purchasing removes supplier links and prices | High | Keep the purchase-order role and supplier pages |
| Daily use of `root` defeats UI simplification | High | Use the restricted `engineer` training account |
| Bulk adjustment can corrupt stock | High | Require preview, permission checks, and a backup first |
| Disabling optional modules deletes data | High | Change visibility/settings only; never delete records |
