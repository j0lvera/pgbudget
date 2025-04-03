-- +goose Up
-- +goose StatementBegin
-- create a function to get transactions for a specific account
create or replace function api.get_account_transactions(p_account_id int)
returns table (
    date timestamp,
    category text,
    description text,
    type text,
    amount decimal
) as $$
begin
    -- return transactions for the specified account
    return query
    select 
        t.date::timestamp,
        -- get the category name (any equity account, including special ones)
        case
            when da.type = 'equity' then da.name
            when ca.type = 'equity' then ca.name
            else 'Uncategorized'
        end as category,
        t.description,
        -- determine transaction type based on debit/credit relationship
        case
            when t.debit_account_id = p_account_id and da.type in ('asset') then 'inflow'
            when t.credit_account_id = p_account_id and ca.type in ('asset') then 'outflow'
            when t.debit_account_id = p_account_id and da.type in ('liability') then 'outflow'
            when t.credit_account_id = p_account_id and ca.type in ('liability') then 'inflow'
            else 'transfer'
        end as type,
        -- calculate the amount from the account's perspective
        case
            when t.debit_account_id = p_account_id and da.type in ('asset') then t.amount
            when t.credit_account_id = p_account_id and ca.type in ('asset') then -t.amount
            when t.debit_account_id = p_account_id and da.type in ('liability') then -t.amount
            when t.credit_account_id = p_account_id and ca.type in ('liability') then t.amount
            else t.amount
        end as amount
    from data.transactions t
    join data.accounts da on t.debit_account_id = da.id
    join data.accounts ca on t.credit_account_id = ca.id
    where t.debit_account_id = p_account_id or t.credit_account_id = p_account_id
    order by t.date desc;
end;
$$ language plpgsql;

-- create a view that uses the function with a default account ID
-- according to conventions, data shape definitions should go in the data schema
create or replace view data.account_transactions as
select * from api.get_account_transactions(4); -- default to account_id 4 (assuming this is a common account)
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the view and function when rolling back
drop view if exists data.account_transactions;
drop function if exists api.get_account_transactions(int);
-- +goose StatementEnd
