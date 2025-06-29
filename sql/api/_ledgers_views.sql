-- File: _ledgers_views.sql
-- Purpose: Defines API views for the ledgers entity.
-- Source: migrations/20250503172238_add_ledgers_api_fns.sql

-- (Assumes api schema exists)
-- (Assumes pgb_web_user role exists)
-- (Assumes data.ledgers table exists)

create or replace view api.ledgers with (security_invoker = true) as
select a.uuid,
       a.name,
       a.description,
       a.metadata,
       a.user_data
  from data.ledgers a;

comment on view api.ledgers is 'Provides a public, RLS-aware view of ledgers. Excludes internal ID and raw audit timestamps (created_at, updated_at).';

grant all on api.ledgers to pgb_web_user;

comment on view api.ledgers is 'Grants all permissions (SELECT, INSERT, UPDATE, DELETE) on the api.ledgers view to the pgb_web_user role. PostgREST can handle mutations on simple views like this directly.';
