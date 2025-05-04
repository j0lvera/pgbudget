-- +goose Up
-- +goose StatementBegin

-- function to add a transaction
-- this function abstract the underlying logic of adding a transaction into a more user-friendly API
create or replace function api.add_transaction(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_type text, -- 'inflow' or 'outflow'
    p_amount bigint,
    p_account_uuid text, -- the bank account or credit card
    p_category_uuid text = null -- the category, now optional
) returns int as
$$
declare
    v_ledger_id             int;
    v_account_id            int;
    v_category_id           int;
    v_transaction_id        int;
    v_debit_account_id      int;
    v_credit_account_id     int;
    v_account_internal_type text;
begin
    -- find the ledger_id from uuid
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid;
    
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found', p_ledger_uuid;
    end if;
    
    -- find the account_id from uuid
    select a.id into v_account_id
    from data.accounts a
    where a.uuid = p_account_uuid and a.ledger_id = v_ledger_id;
    
    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger %', p_account_uuid, p_ledger_uuid;
    end if;
    
    -- validate transaction type
    if p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', p_type;
    end if;

    -- validate amount is positive
    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive: %', p_amount;
    end if;

    -- handle null category by finding the "unassigned" category
    if p_category_uuid is null then
        v_category_id := utils.find_category(p_ledger_uuid, 'Unassigned');
        if v_category_id is null then
            raise exception 'Could not find "unassigned" category in ledger %', p_ledger_uuid;
        end if;
    else
        -- find the category_id from uuid
        select c.id into v_category_id
        from data.accounts c
        where c.uuid = p_category_uuid and c.ledger_id = v_ledger_id;
        
        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger %', p_category_uuid, p_ledger_uuid;
        end if;
    end if;

    -- get the account internal_type (asset_like or liability_like)
    select a.internal_type
      into v_account_internal_type
      from data.accounts a
     where a.id = v_account_id;

    -- determine debit and credit accounts based on account internal_type and transaction type
    if v_account_internal_type = 'asset_like' then
        if p_type = 'inflow' then
            -- for inflow to asset_like: debit asset_like (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
        else
            -- for outflow from asset_like: debit category (decrease), credit asset_like (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
        end if;
    elsif v_account_internal_type = 'liability_like' then
        if p_type = 'inflow' then
            -- for inflow to liability_like: debit category (decrease), credit liability_like (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
        else
            -- for outflow from liability_like: debit liability_like (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
        end if;
    else
        raise exception 'Account internal_type % is not supported for transactions', v_account_internal_type;
    end if;

    -- insert the transaction and return the new id
       insert into data.transactions (ledger_id,
                                      date,
                                      description,
                                      debit_account_id,
                                      credit_account_id,
                                      amount)
       values (v_ledger_id,
               p_date,
               p_description,
               v_debit_account_id,
               v_credit_account_id,
               p_amount)
    returning id into v_transaction_id;

    return v_transaction_id;
end;
$$ language plpgsql;
-- +goose StatementEnd


-- +goose Down
-- +goose StatementBegin
-- drop the functions in reverse order
drop function if exists api.add_transaction(text, timestamptz, text, text, bigint, text, text);
drop function if exists api.find_category(int, text, text);
-- +goose StatementEnd
