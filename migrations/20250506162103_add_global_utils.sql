-- +goose Up
-- +goose StatementBegin

create or replace function utils.set_updated_at_fn()
    returns trigger as
$$
begin
    new.updated_at := current_timestamp;
    return new;
end;
$$ language plpgsql;


create or replace function utils.get_user() returns text as
$$
begin
    -- Try to get application user from session variable first
    -- This allows the Go microservice to set user context per request
    -- Falls back to current_user for tests and direct database access
    return coalesce(
        current_setting('app.current_user_id', true),
        current_user
    );
end;
$$ language plpgsql stable;


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.get_user();

drop function if exists utils.set_updated_at_fn();

-- +goose StatementEnd
