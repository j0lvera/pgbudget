-- +goose Up
-- +goose StatementBegin

-- simple function to calculate account balance on-demand from transactions
create or replace function utils.get_account_balance(
    p_ledger_id bigint,
    p_account_id bigint
) returns bigint as $$
declare
    v_balance bigint := 0;
    v_internal_type text;
    v_account_ledger_id bigint;
begin
    -- get account type and verify it belongs to the specified ledger
    select internal_type, ledger_id 
    into v_internal_type, v_account_ledger_id
    from data.accounts 
    where id = p_account_id;
    
    if v_internal_type is null then
        raise exception 'Account with ID % not found', p_account_id;
    end if;
    
    if v_account_ledger_id != p_ledger_id then
        raise exception 'account not found or does not belong to the specified ledger';
    end if;
    
    -- calculate balance by summing all non-deleted transactions
    -- using ledger_id in WHERE clause for better performance
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
          and (debit_account_id = p_account_id or credit_account_id = p_account_id)
          and deleted_at is null;
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
          and (debit_account_id = p_account_id or credit_account_id = p_account_id)
          and deleted_at is null;
    end if;
    
    return v_balance;
end;
$$ language plpgsql stable security definer;


-- simple function to get account transactions without running balances
create or replace function utils.get_account_transactions(
    p_account_uuid text,
    p_user_data text default utils.get_user()
)
returns table (
    date date,
    category text,
    description text,
    type text,
    amount bigint
) as $$
declare
    v_account_id bigint;
    v_internal_type text;
begin
    -- resolve the account uuid to its internal id and validate ownership
    select a.id, a.internal_type 
    into v_account_id, v_internal_type
    from data.accounts a
    where a.uuid = p_account_uuid and a.user_data = p_user_data;
    
    -- check if account exists and belongs to the user
    if v_account_id is null then
        raise exception 'Account with UUID % not found for current user', p_account_uuid;
    end if;

    -- return account transactions without balance calculation
    return query
    select
        t.date,
        -- get the other account's name as category
        case 
            when t.debit_account_id = v_account_id then 
                (select name from data.accounts where id = t.credit_account_id)
            else 
                (select name from data.accounts where id = t.debit_account_id)
        end as category,
        t.description,
        -- determine transaction type based on account's internal type
        case 
            when (v_internal_type = 'asset_like' and t.debit_account_id = v_account_id) or
                 (v_internal_type = 'liability_like' and t.credit_account_id = v_account_id)
            then 'inflow'
            else 'outflow'
        end as type,
        t.amount
    from 
        data.transactions t
    where 
        (t.debit_account_id = v_account_id or t.credit_account_id = v_account_id)
        and t.deleted_at is null
    order by 
        t.date desc, 
        t.created_at desc;
end;
$$ language plpgsql stable security definer;

-- simple function to get budget status using on-demand balance calculations
create or replace function utils.get_budget_status(
    p_ledger_uuid text,
    p_user_data text default utils.get_user()
)
returns table (
    account_uuid text,
    account_name text,
    budgeted     decimal,
    activity     decimal,
    balance      decimal
) as $$
declare
    v_ledger_id bigint;
begin
    -- find the ledger id and validate ownership
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;
    
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;
    
    -- return budget status for all categories in the ledger
    return query
    with categories as (
        -- get all budget categories (equity accounts except special ones)
        select 
            a.id, 
            a.uuid, 
            a.name
        from 
            data.accounts a
        where 
            a.ledger_id = v_ledger_id
            and a.user_data = p_user_data
            and a.type = 'equity'
            and a.name not in ('Income', 'Off-budget', 'Unassigned')
    ),
    income_account as (
        -- get the income account id for this ledger
        select a.id
        from data.accounts a
        where a.ledger_id = v_ledger_id
          and a.user_data = p_user_data
          and a.type = 'equity'
          and a.name = 'Income'
        limit 1
    ),
    budget_transactions as (
        -- transactions from income to categories (budget allocations)
        select 
            t.credit_account_id as category_id,
            sum(t.amount) as amount
        from 
            data.transactions t
        where 
            t.ledger_id = v_ledger_id
            and t.user_data = p_user_data
            and t.debit_account_id = (select id from income_account)
            and t.deleted_at is null
        group by 
            t.credit_account_id
    ),
    activity_transactions as (
        -- transactions between categories and asset/liability accounts
        select 
            case 
                when t.debit_account_id in (select id from categories) then t.debit_account_id
                else t.credit_account_id
            end as category_id,
            sum(
                case 
                    when t.debit_account_id in (select id from categories) then -t.amount
                    else t.amount
                end
            ) as amount
        from 
            data.transactions t
        where 
            t.ledger_id = v_ledger_id
            and t.user_data = p_user_data
            and (
                (t.debit_account_id in (select id from categories) and 
                 t.credit_account_id in (select id from data.accounts where ledger_id = v_ledger_id and type in ('asset', 'liability'))) or
                (t.credit_account_id in (select id from categories) and 
                 t.debit_account_id in (select id from data.accounts where ledger_id = v_ledger_id and type in ('asset', 'liability')))
            )
            and t.deleted_at is null
        group by 
            case 
                when t.debit_account_id in (select id from categories) then t.debit_account_id
                else t.credit_account_id
            end
    )
    
    -- final result combining all the data
    select 
        c.uuid as account_uuid,
        c.name as account_name,
        coalesce(b.amount, 0)::decimal as budgeted,
        coalesce(a.amount, 0)::decimal as activity,
        utils.get_account_balance(v_ledger_id, c.id)::decimal as balance
    from 
        categories c
    left join 
        budget_transactions b on c.id = b.category_id
    left join 
        activity_transactions a on c.id = a.category_id
    order by 
        c.name;
end;
$$ language plpgsql stable security definer;


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the utility functions
drop function if exists utils.get_budget_status(text, text);
drop function if exists utils.get_account_transactions(text, text);
drop function if exists utils.get_account_balance(bigint, bigint);

-- +goose StatementEnd
