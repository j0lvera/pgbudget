-- +goose Up
-- +goose StatementBegin

-- first, drop all existing api.get_budget_status functions to avoid overloading conflicts
drop function if exists api.get_budget_status(text);
drop function if exists api.get_budget_status(text, text);

-- enhance utils.get_budget_status to support optional date filtering for month view
-- this maintains backward compatibility while adding period-based budget reporting
create or replace function utils.get_budget_status(
    p_ledger_uuid text,
    p_user_data text default utils.get_user(),
    p_start_date date default null,
    p_end_date date default null
) returns table(
    account_uuid text,
    account_name text,
    budgeted decimal,
    activity decimal,
    balance decimal
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
        -- apply date filter if provided
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
            and (p_start_date is null or t.date >= p_start_date)
            and (p_end_date is null or t.date <= p_end_date)
        group by
            t.credit_account_id
    ),
    activity_transactions as (
        -- transactions between categories and asset/liability accounts
        -- apply date filter if provided
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
            and (p_start_date is null or t.date >= p_start_date)
            and (p_end_date is null or t.date <= p_end_date)
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
        -- for balance, use all-time balance if no date filter, otherwise calculate period balance
        case 
            when p_start_date is null and p_end_date is null then
                utils.get_account_balance(v_ledger_id, c.id)::decimal
            else
                (coalesce(b.amount, 0) + coalesce(a.amount, 0))::decimal
        end as balance
    from
        categories c
    left join
        budget_transactions b on c.id = b.category_id
    left join
        activity_transactions a on c.id = a.category_id
    order by
        c.name;
end;
$$ language plpgsql;

-- create new api.get_budget_status with optional period parameter
-- period format: YYYYMM (e.g., '202508' for August 2025)
-- maintains backward compatibility with existing calls
create function api.get_budget_status(
    p_ledger_uuid text,
    p_period text default null
) returns table(
    category_uuid text, 
    category_name text, 
    budgeted bigint, 
    activity bigint, 
    balance bigint
) as $$
declare
    v_start_date date;
    v_end_date date;
begin
    -- parse period parameter if provided
    if p_period is not null then
        -- validate period format (YYYYMM)
        if p_period !~ '^\d{6}$' then
            raise exception 'Invalid period format. Use YYYYMM (e.g., 202508)';
        end if;
        
        -- extract year and month to create date range
        v_start_date := (p_period || '01')::date;  -- first day of month
        v_end_date := (v_start_date + interval '1 month - 1 day')::date;  -- last day of month
        
        -- if end date is in the future, use today instead
        if v_end_date > current_date then
            v_end_date := current_date;
        end if;
    end if;
    
    -- call the enhanced utils function with date parameters
    return query
    select 
        bs.account_uuid as category_uuid,
        bs.account_name as category_name,
        bs.budgeted::bigint,
        bs.activity::bigint,
        bs.balance::bigint
    from utils.get_budget_status(p_ledger_uuid, utils.get_user(), v_start_date, v_end_date) bs;
end;
$$ language plpgsql;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the enhanced function
drop function if exists api.get_budget_status(text, text);

-- restore original utils.get_budget_status function without date parameters
create or replace function utils.get_budget_status(
    p_ledger_uuid text,
    p_user_data text default utils.get_user()
) returns table(
    account_uuid text,
    account_name text,
    budgeted decimal,
    activity decimal,
    balance decimal
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
$$ language plpgsql;

-- restore original api.get_budget_status function without period parameter
create function api.get_budget_status(
    p_ledger_uuid text
) returns table(
    category_uuid text, 
    category_name text, 
    budgeted bigint, 
    activity bigint, 
    balance bigint
) as $$
begin
    -- simply call the utils function and transform the results for the api
    return query
    select
        bs.account_uuid as category_uuid,
        bs.account_name as category_name,
        bs.budgeted::bigint,
        bs.activity::bigint,
        bs.balance::bigint
    from utils.get_budget_status(p_ledger_uuid) bs;
end;
$$ language plpgsql;

-- +goose StatementEnd
