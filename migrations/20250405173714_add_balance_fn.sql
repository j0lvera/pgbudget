-- +goose Up
-- +goose StatementBegin
create or replace function api.get_account_balance(
    p_ledger_id integer,
    p_account_id integer
) returns numeric as $$
declare
    v_internal_type text;
    v_balance numeric;
begin
    -- get the internal type of the account (asset_like or liability_like)
    select internal_type into v_internal_type
    from data.accounts
    where id = p_account_id and ledger_id = p_ledger_id;

    if v_internal_type is null then
        raise exception 'account not found or does not belong to the specified ledger';
    end if;

    -- calculate balance based on internal type
    -- for asset-like accounts: debits increase (positive), credits decrease (negative)
    -- for liability-like accounts: credits increase (positive), debits decrease (negative)
    if v_internal_type = 'asset_like' then
        select coalesce(sum(
            case
                when debit_account_id = p_account_id then amount
                when credit_account_id = p_account_id then -amount
                else 0
            end
        ), 0) into v_balance
        from data.transactions
        where ledger_id = p_ledger_id
        and (debit_account_id = p_account_id or credit_account_id = p_account_id);
    else -- liability_like
        select coalesce(sum(
            case
                when credit_account_id = p_account_id then amount
                when debit_account_id = p_account_id then -amount
                else 0
            end
        ), 0) into v_balance
        from data.transactions
        where ledger_id = p_ledger_id
        and (debit_account_id = p_account_id or credit_account_id = p_account_id);
    end if;

    return v_balance;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop function if exists api.get_account_balance;
-- +goose StatementEnd
