-- +goose Up
-- +goose StatementBegin

-- create balance snapshots table - one record per transaction per affected account
create table data.balance_snapshots
(
    id bigint generated always as identity,
    account_id bigint not null,
    transaction_id bigint not null,
    balance bigint not null,
    created_at timestamptz not null default current_timestamp,
    user_data text not null default utils.get_user(),

    constraint balance_snapshots_id_pk primary key (id),
    constraint balance_snapshots_account_id_fk foreign key (account_id) references data.accounts(id),
    constraint balance_snapshots_transaction_id_fk foreign key (transaction_id) references data.transactions(id),
    constraint balance_snapshots_account_transaction_unique unique (account_id, transaction_id, user_data)
);

-- index for fast current balance lookups (latest transaction per account)
create index idx_balance_snapshots_account_transaction on data.balance_snapshots(account_id, transaction_id desc);

-- index for user data isolation
create index idx_balance_snapshots_user_data on data.balance_snapshots(user_data);

-- index for transaction-based queries
create index idx_balance_snapshots_transaction_id on data.balance_snapshots(transaction_id);

-- function to get current balance for an account (latest snapshot)
create or replace function utils.get_account_current_balance(
    p_account_id bigint
) returns bigint as $$
declare
    v_balance bigint;
begin
    -- get the most recent balance snapshot for this account
    select balance into v_balance
    from data.balance_snapshots
    where account_id = p_account_id 
      and user_data = utils.get_user()
    order by transaction_id desc
    limit 1;
    
    return coalesce(v_balance, 0);
end;
$$ language plpgsql security definer;

-- function to create balance snapshots for a transaction
create or replace function utils.create_balance_snapshots(
    p_transaction_id bigint
) returns void as $$
declare
    v_transaction data.transactions;
    v_debit_account data.accounts;
    v_credit_account data.accounts;
    v_debit_balance bigint;
    v_credit_balance bigint;
begin
    -- get transaction details
    select * into v_transaction
    from data.transactions
    where id = p_transaction_id and user_data = utils.get_user();
    
    if v_transaction.id is null then
        return; -- transaction not found or not owned by user
    end if;
    
    -- get account details for proper balance calculation
    select * into v_debit_account
    from data.accounts
    where id = v_transaction.debit_account_id and user_data = utils.get_user();
    
    select * into v_credit_account
    from data.accounts
    where id = v_transaction.credit_account_id and user_data = utils.get_user();
    
    -- calculate new balances based on account types and double-entry rules
    -- for debit account: assets increase with debits, equity/liability decrease with debits
    if v_debit_account.internal_type = 'asset_like' then
        v_debit_balance := utils.get_account_current_balance(v_transaction.debit_account_id) + v_transaction.amount;
    else -- equity_like or liability_like
        v_debit_balance := utils.get_account_current_balance(v_transaction.debit_account_id) - v_transaction.amount;
    end if;
    
    -- for credit account: assets decrease with credits, equity/liability increase with credits
    if v_credit_account.internal_type = 'asset_like' then
        v_credit_balance := utils.get_account_current_balance(v_transaction.credit_account_id) - v_transaction.amount;
    else -- equity_like or liability_like
        v_credit_balance := utils.get_account_current_balance(v_transaction.credit_account_id) + v_transaction.amount;
    end if;
    
    -- create balance snapshot for debit account
    insert into data.balance_snapshots (account_id, transaction_id, balance, user_data)
    values (v_transaction.debit_account_id, p_transaction_id, v_debit_balance, utils.get_user())
    on conflict (account_id, transaction_id, user_data) do nothing;
    
    -- create balance snapshot for credit account
    insert into data.balance_snapshots (account_id, transaction_id, balance, user_data)
    values (v_transaction.credit_account_id, p_transaction_id, v_credit_balance, utils.get_user())
    on conflict (account_id, transaction_id, user_data) do nothing;
end;
$$ language plpgsql security definer;

-- function to rebuild all balance snapshots for an account (for data repair)
create or replace function utils.rebuild_account_balance_snapshots(
    p_account_id bigint
) returns void as $$
declare
    v_transaction record;
    v_account data.accounts;
    v_running_balance bigint := 0;
begin
    -- get account details for proper balance calculation
    select * into v_account
    from data.accounts
    where id = p_account_id and user_data = utils.get_user();
    
    if v_account.id is null then
        return; -- account not found or not owned by user
    end if;
    
    -- delete existing snapshots for this account
    delete from data.balance_snapshots
    where account_id = p_account_id and user_data = utils.get_user();
    
    -- rebuild snapshots by processing transactions in chronological order
    for v_transaction in
        select id, amount,
               case 
                   when debit_account_id = p_account_id then
                       case when v_account.internal_type = 'asset_like' then amount
                            else -amount end
                   when credit_account_id = p_account_id then
                       case when v_account.internal_type = 'asset_like' then -amount
                            else amount end
                   else 0 
               end as balance_change
        from data.transactions
        where (debit_account_id = p_account_id or credit_account_id = p_account_id)
          and user_data = utils.get_user()
        order by id
    loop
        v_running_balance := v_running_balance + v_transaction.balance_change;
        
        insert into data.balance_snapshots (account_id, transaction_id, balance, user_data)
        values (p_account_id, v_transaction.id, v_running_balance, utils.get_user());
    end loop;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.rebuild_account_balance_snapshots(bigint);
drop function if exists utils.create_balance_snapshots(bigint);
drop function if exists utils.get_account_current_balance(bigint);
drop table if exists data.balance_snapshots;

-- +goose StatementEnd
