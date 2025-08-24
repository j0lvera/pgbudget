-- +goose Up
-- +goose StatementBegin

-- utils function to get account balance from snapshots (internal)
create or replace function utils.get_account_balance_from_snapshots(
    p_account_uuid text
) returns bigint as $$
declare
    v_account_id bigint;
begin
    -- get account id
    select id into v_account_id
    from data.accounts
    where uuid = p_account_uuid and user_data = utils.get_user();
    
    if v_account_id is null then
        raise exception 'account not found or does not belong to the specified ledger: %', p_account_uuid;
    end if;
    
    return utils.get_account_current_balance(v_account_id);
end;
$$ language plpgsql security definer;

-- api function to get account balance (public interface)
create or replace function api.get_account_balance(
    p_account_uuid text
) returns bigint as $$
begin
    return utils.get_account_balance_from_snapshots(p_account_uuid);
end;
$$ language plpgsql security definer;

-- utils function to get balance history for an account (internal)
create or replace function utils.get_account_balance_history(
    p_account_uuid text,
    p_limit int default 100
) returns table(
    transaction_id bigint,
    balance bigint,
    created_at timestamptz
) as $$
declare
    v_account_id bigint;
begin
    -- get account id
    select id into v_account_id
    from data.accounts
    where uuid = p_account_uuid and user_data = utils.get_user();
    
    if v_account_id is null then
        raise exception 'Account not found: %', p_account_uuid;
    end if;
    
    -- return balance history for the account
    return query
    select 
        bs.transaction_id,
        bs.balance,
        bs.created_at
    from data.balance_snapshots bs
    where bs.account_id = v_account_id 
      and bs.user_data = utils.get_user()
    order by bs.transaction_id desc
    limit p_limit;
end;
$$ language plpgsql security definer;

-- api function to get balance history for an account (public interface)
create or replace function api.get_account_balance_history(
    p_account_uuid text,
    p_limit int default 100
) returns table(
    transaction_id bigint,
    balance bigint,
    created_at timestamptz
) as $$
begin
    return query
    select * from utils.get_account_balance_history(p_account_uuid, p_limit);
end;
$$ language plpgsql security definer;

-- utils function to get all current balances for a ledger (internal)
create or replace function utils.get_ledger_current_balances(
    p_ledger_uuid text
) returns table(
    account_uuid text,
    account_name text,
    account_type text,
    current_balance bigint
) as $$
declare
    v_ledger_id bigint;
begin
    -- get ledger id
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();
    
    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;
    
    -- return current balance for each account in the ledger
    return query
    select 
        a.uuid::text,
        a.name,
        a.type,
        coalesce(utils.get_account_current_balance(a.id), 0)
    from data.accounts a
    where a.ledger_id = v_ledger_id 
      and a.user_data = utils.get_user()
    order by a.type, a.name;
end;
$$ language plpgsql security definer;

-- api function to get all current balances for a ledger (public interface)
create or replace function api.get_ledger_balances(
    p_ledger_uuid text
) returns table(
    account_uuid text,
    account_name text,
    account_type text,
    current_balance bigint
) as $$
begin
    return query
    select 
        u.account_uuid,
        u.account_name,
        u.account_type,
        u.current_balance
    from utils.get_ledger_current_balances(p_ledger_uuid) u;
end;
$$ language plpgsql security definer;

-- utils function to rebuild balance snapshots for a ledger (internal)
create or replace function utils.rebuild_ledger_balance_snapshots(
    p_ledger_uuid text
) returns void as $$
declare
    v_ledger_id bigint;
    v_account record;
begin
    -- get ledger id
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();
    
    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;
    
    -- rebuild snapshots for each account in the ledger
    for v_account in
        select id from data.accounts
        where ledger_id = v_ledger_id and user_data = utils.get_user()
    loop
        perform utils.rebuild_account_balance_snapshots(v_account.id);
    end loop;
end;
$$ language plpgsql security definer;

-- api function to rebuild balance snapshots for a ledger (public interface)
create or replace function api.rebuild_ledger_balance_snapshots(
    p_ledger_uuid text
) returns void as $$
begin
    perform utils.rebuild_ledger_balance_snapshots(p_ledger_uuid);
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists api.rebuild_ledger_balance_snapshots(text);
drop function if exists utils.rebuild_ledger_balance_snapshots(text);
drop function if exists api.get_ledger_balances(text);
drop function if exists utils.get_ledger_current_balances(text);
drop function if exists api.get_account_balance_history(text, int);
drop function if exists utils.get_account_balance_history(text, int);
drop function if exists api.get_account_balance(text);
drop function if exists utils.get_account_balance_from_snapshots(text);

-- +goose StatementEnd
