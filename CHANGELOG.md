CHANGES
=======

V 0.4.3
----------

- Dropped the library dependency on `selecto_components`; PostgreSQL adapter
  ownership now stays focused on the Selecto database-adapter contract without
  pulling UI package test/runtime dependencies.
- Updated README dependency guidance for the coordinated point release.
- Bump package version to `0.4.3`.

V 0.4.2
----------

- Dropped the library dependency on `selecto_updato`; PostgreSQL write-adapter
  ownership now stays inside `selecto_updato`'s generic write path instead of a
  package-local `UpdatoAdapter` module.
- Added `list_relations/2` support so PostgreSQL adapter introspection can
  return tables, views, and materialized views for DB-backed generator flows.
- Added `refresh_materialized_view/3` support, including concurrent refresh SQL
  for materialized-view publication workflows.
- Bump package version to `0.4.2`.

V 0.4.1
--------

- Relaxed the `selecto` dependency to allow releases from `0.4.0` up to `0.5.x`.
- Bump package version to `0.4.1`.

V 0.4.0
--------

- Introduced the standalone PostgreSQL adapter package for the external
  Selecto adapter architecture.
- Added PostgreSQL-owned hooks for execution, pooling, streaming, diagnostics,
  server version detection, and repo fallback behavior.
- Dropped the standalone `selecto_db_adapter` dependency now that
  `Selecto.DB.Adapter` ships with `selecto`.
- Updated installation guidance to depend directly on `selecto` plus
  `selecto_db_postgresql`.
- Bump package version to `0.4.0`.
