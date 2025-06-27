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
    return current_user;
end;
$$ language plpgsql stable;


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.get_user();

drop function if exists utils.set_updated_at_fn();

-- +goose StatementEnd
