-- +goose Up
-- +goose StatementBegin

-- create utils function to get income transactions with optional period filtering
-- this respects the same date filtering as budget_status for consistency
create function utils.get_income_total(
    p_ledger_uuid text,
    p_user_data text default utils.get_user(),
    p_start_date date default null,
    p_end_date date default null
) returns bigint as $$
declare
    v_ledger_id bigint;
    v_income_total bigint;
begin
    -- find the ledger id and validate ownership
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- calculate total income for the period
    -- income transactions are those that credit the Income account from asset/liability accounts
    select coalesce(sum(t.amount), 0) into v_income_total
    from data.transactions t
    join data.accounts income_acc on t.credit_account_id = income_acc.id
    join data.accounts source_acc on t.debit_account_id = source_acc.id
    where t.ledger_id = v_ledger_id
      and t.user_data = p_user_data
      and t.deleted_at is null
      and income_acc.name = 'Income'
      and income_acc.type = 'equity'
      and source_acc.type in ('asset', 'liability')
      and (p_start_date is null or t.date >= p_start_date)
      and (p_end_date is null or t.date <= p_end_date);

    return v_income_total;
end;
$$ language plpgsql;

-- create new api function for budget totals
-- returns: income, income_remaining_from_last_month, budgeted, left_to_budget
create function api.get_budget_totals(
    p_ledger_uuid text,
    p_period text default null
) returns table(
    income bigint,
    income_remaining_from_last_month bigint,
    budgeted bigint,
    left_to_budget bigint
) as $$
declare
    v_start_date date;
    v_end_date date;
    v_prev_month_end date;
    v_income_total bigint;
    v_income_remaining bigint;
    v_total_budgeted bigint;
    v_income_balance bigint;
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
        
        -- calculate previous month end for income remaining calculation
        v_prev_month_end := v_start_date - interval '1 day';
    end if;
    
    -- get total income for the period
    v_income_total := utils.get_income_total(p_ledger_uuid, utils.get_user(), v_start_date, v_end_date);
    
    -- get income remaining from last month (only for month view)
    if p_period is not null then
        -- get income account balance as of end of previous month
        select coalesce(
            (select utils.get_account_balance(
                (select id from data.ledgers where uuid = p_ledger_uuid),
                a.id
            ) - utils.get_income_total(p_ledger_uuid, utils.get_user(), v_start_date, null)), 0
        ) into v_income_remaining
        from data.accounts a
        where a.ledger_id = (select id from data.ledgers where uuid = p_ledger_uuid)
          and a.user_data = utils.get_user()
          and a.name = 'Income'
          and a.type = 'equity';
    else
        v_income_remaining := 0;
    end if;
    
    -- calculate total budgeted (sum of all category budgeted amounts for the period)
    select coalesce(sum(bs.budgeted), 0) into v_total_budgeted
    from utils.get_budget_status(p_ledger_uuid, utils.get_user(), v_start_date, v_end_date) bs;
    
    -- get current income account balance (left to budget)
    select coalesce(utils.get_account_balance(
        (select id from data.ledgers where uuid = p_ledger_uuid),
        a.id
    ), 0) into v_income_balance
    from data.accounts a
    where a.ledger_id = (select id from data.ledgers where uuid = p_ledger_uuid)
      and a.user_data = utils.get_user()
      and a.name = 'Income'
      and a.type = 'equity';
    
    -- return the totals
    return query
    select 
        v_income_total as income,
        v_income_remaining as income_remaining_from_last_month,
        v_total_budgeted as budgeted,
        v_income_balance as left_to_budget;
end;
$$ language plpgsql;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the new budget totals function
drop function if exists api.get_budget_totals(text, text);

-- drop the recreated budget status function
drop function if exists api.get_budget_status(text, text);

-- drop the utility functions
drop function if exists utils.get_income_total(text, text, date, date);

-- +goose StatementEnd