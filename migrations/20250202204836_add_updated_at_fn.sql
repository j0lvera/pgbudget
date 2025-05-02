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
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop function utils.set_updated_at_fn();
-- +goose StatementEnd
