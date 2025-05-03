-- +goose Up
-- +goose StatementBegin

-- create a function to handle balance insertion through the API view
create or replace function utils.balances_insert_single_fn() returns trigger as
$$
declare
    v_account_id bigint;
    v_transaction_id bigint;
begin
    -- get the account_id from uuid
    select a.id
      into v_account_id
      from data.accounts a
     where a.uuid = NEW.account_uuid;

    if v_account_id is null then
        raise exception 'account with uuid % not found', NEW.account_uuid;
    end if;

    -- get the transaction_id from uuid if provided
    if NEW.transaction_uuid is not null then
        select t.id
          into v_transaction_id
          from data.transactions t
         where t.uuid = NEW.transaction_uuid;

        if v_transaction_id is null then
            raise exception 'transaction with uuid % not found', NEW.transaction_uuid;
        end if;
    end if;

    -- insert the balance into the balances table
    insert into data.balances (
        account_id, 
        transaction_id, 
        previous_balance, 
        delta, 
        balance, 
        operation_type, 
        metadata
    )
    values (
        v_account_id,
        v_transaction_id,
        NEW.previous_balance,
        NEW.delta,
        NEW.balance,
        NEW.operation_type,
        NEW.metadata
    )
    returning uuid, previous_balance, delta, balance, operation_type, metadata, user_data into
        new.uuid, new.previous_balance, new.delta, new.balance, new.operation_type, new.metadata, new.user_data;

    return new;
end;
$$ language plpgsql;

-- create the API view for balances
create or replace view api.balances with (security_invoker = true) as
select b.uuid,
       b.previous_balance,
       b.delta,
       b.balance,
       b.operation_type,
       b.metadata,
       b.user_data,
       b.created_at,
       (select a.uuid from data.accounts a where a.id = b.account_id)::text as account_uuid,
       (select t.uuid from data.transactions t where t.id = b.transaction_id)::text as transaction_uuid
  from data.balances b;

-- create the insert trigger for the balances view
create trigger balances_insert_tg
    instead of insert
    on api.balances
    for each row
execute function utils.balances_insert_single_fn();

-- grant permissions to the web user
grant all on api.balances to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

revoke all on api.balances from pgb_web_user;

drop trigger if exists balances_insert_tg on api.balances;

drop view if exists api.balances;

drop function if exists utils.balances_insert_single_fn();

-- +goose StatementEnd
