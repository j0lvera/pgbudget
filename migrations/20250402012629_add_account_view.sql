-- +goose Up
-- +goose StatementBegin
-- We've already defined the get_account_transactions function in the previous migration,
-- so we'll just create the view here

-- Create a view for the default account
create or replace view data.account_transactions as
select * from api.get_account_transactions(4);  -- Default account ID
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop view if exists data.account_transactions;
-- +goose StatementEnd
