-- +goose Up
-- +goose StatementBegin

-- create the data.balances table that tests expect
create table if not exists data.balances (
    id bigint generated always as identity primary key,
    
    created_at timestamptz not null default current_timestamp,
    updated_at timestamptz not null default current_timestamp,
    
    account_id bigint not null,
    transaction_id bigint,
    
    previous_balance bigint not null default 0,
    delta bigint not null,
    new_balance bigint not null,
    
    operation_type text not null,
    user_data text not null default utils.get_user(),
    
    constraint balances_account_id_fkey foreign key (account_id) references data.accounts(id),
    constraint balances_transaction_id_fkey foreign key (transaction_id) references data.transactions(id),
    constraint balances_operation_type_check check (operation_type in (
        'transaction_insert', 
        'transaction_update_reversal', 
        'transaction_update_application',
        'transaction_soft_delete'
    ))
);

-- enable RLS on balances table
alter table data.balances enable row level security;

-- create RLS policy for balances
create policy balances_policy on data.balances
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

-- create indexes for performance
create index if not exists balances_account_id_idx on data.balances(account_id);
create index if not exists balances_transaction_id_idx on data.balances(transaction_id);
create index if not exists balances_created_at_idx on data.balances(created_at desc);

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
        raise exception 'Account not found or does not belong to the specified ledger';
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

-- function to update balance entries when transactions change
create or replace function utils.update_account_balances(
    p_transaction_id bigint,
    p_debit_account_id bigint,
    p_credit_account_id bigint,
    p_amount bigint,
    p_operation_type text,
    p_user_data text default utils.get_user()
) returns void as $$
declare
    v_debit_prev_balance bigint;
    v_credit_prev_balance bigint;
    v_debit_delta bigint;
    v_credit_delta bigint;
    v_debit_internal_type text;
    v_credit_internal_type text;
    v_ledger_id bigint;
begin
    -- get account types and ledger_id
    select internal_type into v_debit_internal_type
    from data.accounts where id = p_debit_account_id;
    
    select internal_type, ledger_id into v_credit_internal_type, v_ledger_id
    from data.accounts where id = p_credit_account_id;
    
    -- get previous balances
    v_debit_prev_balance := utils.get_account_balance(v_ledger_id, p_debit_account_id);
    v_credit_prev_balance := utils.get_account_balance(v_ledger_id, p_credit_account_id);
    
    -- calculate deltas based on operation type
    if p_operation_type = 'transaction_insert' then
        -- for inserts, apply the transaction amounts
        if v_debit_internal_type = 'asset_like' then
            v_debit_delta := p_amount; -- debit increases asset
        else
            v_debit_delta := -p_amount; -- debit decreases liability/equity
        end if;
        
        if v_credit_internal_type = 'asset_like' then
            v_credit_delta := -p_amount; -- credit decreases asset
        else
            v_credit_delta := p_amount; -- credit increases liability/equity
        end if;
    elsif p_operation_type = 'transaction_update_reversal' then
        -- for update reversals, reverse the original transaction
        if v_debit_internal_type = 'asset_like' then
            v_debit_delta := -p_amount; -- reverse the debit
        else
            v_debit_delta := p_amount; -- reverse the debit
        end if;
        
        if v_credit_internal_type = 'asset_like' then
            v_credit_delta := p_amount; -- reverse the credit
        else
            v_credit_delta := -p_amount; -- reverse the credit
        end if;
    elsif p_operation_type = 'transaction_update_application' then
        -- for update applications, apply the new amounts
        if v_debit_internal_type = 'asset_like' then
            v_debit_delta := p_amount; -- apply new debit
        else
            v_debit_delta := -p_amount; -- apply new debit
        end if;
        
        if v_credit_internal_type = 'asset_like' then
            v_credit_delta := -p_amount; -- apply new credit
        else
            v_credit_delta := p_amount; -- apply new credit
        end if;
    elsif p_operation_type = 'transaction_soft_delete' then
        -- for soft deletes, reverse the transaction
        if v_debit_internal_type = 'asset_like' then
            v_debit_delta := -p_amount; -- reverse the debit
        else
            v_debit_delta := p_amount; -- reverse the debit
        end if;
        
        if v_credit_internal_type = 'asset_like' then
            v_credit_delta := p_amount; -- reverse the credit
        else
            v_credit_delta := -p_amount; -- reverse the credit
        end if;
    end if;
    
    -- insert balance entries for both accounts
    insert into data.balances (
        account_id, transaction_id, previous_balance, delta, new_balance, operation_type, user_data
    ) values (
        p_debit_account_id, p_transaction_id, v_debit_prev_balance, v_debit_delta, 
        v_debit_prev_balance + v_debit_delta, p_operation_type, p_user_data
    );
    
    insert into data.balances (
        account_id, transaction_id, previous_balance, delta, new_balance, operation_type, user_data
    ) values (
        p_credit_account_id, p_transaction_id, v_credit_prev_balance, v_credit_delta, 
        v_credit_prev_balance + v_credit_delta, p_operation_type, p_user_data
    );
end;
$$ language plpgsql volatile security definer;

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
    amount bigint,
    balance bigint
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

    -- return account transactions with simple balance calculation
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
        t.amount,
        -- calculate balance on-demand (this will be slow for large datasets)
        (select utils.get_account_balance(a.ledger_id, v_account_id) 
         from data.accounts a where a.id = v_account_id) as balance
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

-- compatibility function for tests that expect the old single-parameter signature
create or replace function utils.get_latest_account_balance(
    p_account_id bigint
) returns bigint as $$
begin
    -- get the ledger_id for the account and call the updated function
    return (
        select utils.get_account_balance(a.ledger_id, p_account_id)
        from data.accounts a
        where a.id = p_account_id
    );
end;
$$ language plpgsql stable security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the utility functions
drop function if exists utils.get_budget_status(text, text);
drop function if exists utils.get_account_transactions(text, text);
drop function if exists utils.get_account_balance(bigint, bigint);
drop function if exists utils.get_latest_account_balance(bigint);
drop function if exists utils.update_account_balances(bigint, bigint, bigint, bigint, text, text);

-- drop the balances table
drop table if exists data.balances;

-- +goose StatementEnd
