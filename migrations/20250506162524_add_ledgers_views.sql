-- +goose Up
-- +goose StatementBegin

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

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

revoke all on api.ledgers from pgb_web_user;

drop view if exists api.ledgers;

-- +goose StatementEnd
