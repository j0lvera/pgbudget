-- +goose Up
-- +goose StatementBegin

create or replace view api.ledgers with (security_barrier) as
select a.uuid,
       a.name,
       a.description,
       a.metadata,
       a.user_data
  from data.ledgers a;

grant all on api.ledgers to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

revoke all on api.ledgers from pgb_web_user;

drop view if exists api.ledgers;

-- +goose StatementEnd
