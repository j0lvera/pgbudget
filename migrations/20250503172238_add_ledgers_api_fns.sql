-- +goose Up
-- +goose StatementBegin

-- function to create a new ledger
create or replace function utils.ledgers_insert_single(
    p_user_data text,
    p_name text,
    p_description text default null
)
    returns table
            (
                uuid        text,
                name        text,
                description text,
                metadata    jsonb
            )
as
$$
begin
    -- insert and return the requested fields in one operation
    return query
        insert into data.ledgers (user_data, name, description)
            values (p_user_data, p_name, p_description)
            returning ledgers.uuid, ledgers.name, ledgers.description, ledgers.metadata;
end;
$$ language plpgsql;

-- api function to create a new ledger
create or replace function api.add_ledger(
    p_name text,
    p_description text default null
)
    returns table
            (
                uuid        text,
                name        text,
                description text,
                metadata    jsonb
            )
as
$$
begin
    return query
        select *
          from utils.ledgers_insert_single(
                  utils.get_user(),
                  p_name,
                  p_description
               );
end;
$$ language plpgsql;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the functions
drop function if exists api.add_ledger(text, text);
drop function if exists utils.ledgers_insert_single(text, text, text);

-- +goose StatementEnd
