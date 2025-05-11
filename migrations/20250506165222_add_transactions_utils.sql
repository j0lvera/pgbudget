-- +goose Up
-- +goose StatementBegin

-- function to add a transaction
-- this function abstract the underlying logic of adding a transaction into a more user-friendly API
create or replace function utils.add_transaction(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_type text, -- 'inflow' or 'outflow'
    p_amount bigint,
    p_account_uuid text, -- the bank account or credit card
    p_category_uuid text = null, -- the category, now optional
    p_user_data text = utils.get_user() -- Add user context parameter
) returns int as
$$
declare
    v_ledger_id             int;
    v_account_id            int;
    v_account_internal_type text;
    v_category_id           int;
    v_transaction_id        int;
    v_debit_account_id      int;
    v_credit_account_id     int;
begin
    -- validate inputs early for fast failure
    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive: %', p_amount;
    end if;

    if p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', p_type;
    end if;

    -- find the ledger_id from uuid and validate ownership
    select l.id into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- find the account_id and internal_type in one query
    select a.id, a.internal_type 
      into v_account_id, v_account_internal_type
      from data.accounts a
     where a.uuid = p_account_uuid 
       and a.ledger_id = v_ledger_id
       and a.user_data = p_user_data;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger % for current user', 
                       p_account_uuid, p_ledger_uuid;
    end if;

    -- handle category lookup
    if p_category_uuid is null then
        -- find the "Unassigned" category directly
        select a.id into v_category_id
          from data.accounts a
         where a.ledger_id = v_ledger_id
           and a.user_data = p_user_data
           and a.name = 'Unassigned'
           and a.type = 'equity';
           
        if v_category_id is null then
            raise exception 'Could not find "Unassigned" category in ledger % for current user', 
                           p_ledger_uuid;
        end if;
    else
        -- find the specified category
        select a.id into v_category_id
          from data.accounts a
         where a.uuid = p_category_uuid 
           and a.ledger_id = v_ledger_id
           and a.user_data = p_user_data;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger % for current user', 
                           p_category_uuid, p_ledger_uuid;
        end if;
    end if;

    -- determine debit and credit accounts based on account type and transaction type
    -- following double-entry accounting principles from SPEC.md
    case 
        when v_account_internal_type = 'asset_like' and p_type = 'inflow' then
            -- inflow to asset: debit asset (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        when v_account_internal_type = 'asset_like' and p_type = 'outflow' then
            -- outflow from asset: debit category (decrease), credit asset (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and p_type = 'inflow' then
            -- inflow to liability: debit category (decrease), credit liability (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and p_type = 'outflow' then
            -- outflow from liability: debit liability (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        else
            raise exception 'Unsupported combination: account_type=% and transaction_type=%', 
                           v_account_internal_type, p_type;
    end case;

    -- insert the transaction and return the new id
    insert into data.transactions (
        ledger_id,
        date,
        description,
        debit_account_id,
        credit_account_id,
        amount,
        user_data
    )
    values (
        v_ledger_id,
        p_date,
        p_description,
        v_debit_account_id,
        v_credit_account_id,
        p_amount,
        p_user_data
    )
    returning id into v_transaction_id;

    return v_transaction_id;
end;
$$ language plpgsql security definer;


-- function to assign money from Income to a category (internal utility)
-- performs the core logic: finds accounts, validates, inserts transaction
-- returns a record matching the api.transactions view structure
create or replace function utils.assign_to_category(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text,
    p_user_data text = utils.get_user()
) returns table(
    -- results (fields returned by this function)
    r_uuid text,                  
    r_description text,           
    r_amount bigint,              
    r_date timestamptz,           
    r_metadata jsonb,             
    r_ledger_uuid text,           
    r_transaction_type text,      
    r_account_uuid text,          
    r_category_uuid text          
) as
$$
declare
    v_ledger_id int;
    v_income_account_id int;
    v_income_account_uuid text;
    v_category_account_id int;
    v_transaction_uuid text;
    v_metadata jsonb;
begin
    -- validate input parameters early
    if p_amount <= 0 then 
        raise exception 'Assignment amount must be positive: %', p_amount; 
    end if;

    -- find ledger ID and validate ownership in a single query
    select l.id into v_ledger_id 
    from data.ledgers l 
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;
    
    if v_ledger_id is null then 
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid; 
    end if;

    -- find both Income account and target category in one efficient query
    with account_data as (
        select a.id, a.uuid, a.name, a.type
        from data.accounts a
        where a.ledger_id = v_ledger_id 
          and a.user_data = p_user_data
          and ((a.name = 'Income' and a.type = 'equity') or a.uuid = p_category_uuid)
    )
    select 
        (select id from account_data where name = 'Income' and type = 'equity'),
        (select uuid from account_data where name = 'Income' and type = 'equity'),
        (select id from account_data where uuid = p_category_uuid)
    into v_income_account_id, v_income_account_uuid, v_category_account_id;

    -- validate accounts were found
    if v_income_account_id is null then 
        raise exception 'Income account not found for ledger % and user %', v_ledger_id, p_user_data; 
    end if;
    
    if v_category_account_id is null then 
        raise exception 'Category with UUID % not found or does not belong to ledger % for current user', 
                        p_category_uuid, v_ledger_id; 
    end if;

    -- create the transaction (debit Income, credit Category)
    insert into data.transactions (
        ledger_id, 
        description, 
        date, 
        amount, 
        debit_account_id, 
        credit_account_id, 
        user_data
    ) values (
        v_ledger_id, 
        p_description, 
        p_date, 
        p_amount, 
        v_income_account_id, 
        v_category_account_id, 
        p_user_data
    ) returning uuid, metadata into v_transaction_uuid, v_metadata;

    -- return the full record matching the api.transactions view structure
    -- using a single VALUES expression is more efficient than a subquery
    return query
    values (
        v_transaction_uuid,     -- r_uuid
        p_description,          -- r_description
        p_amount,               -- r_amount
        p_date,                 -- r_date
        v_metadata,             -- r_metadata
        p_ledger_uuid,          -- r_ledger_uuid
        null::text,             -- r_transaction_type (null for direct assignments)
        v_income_account_uuid,  -- r_account_uuid (using Income account)
        p_category_uuid         -- r_category_uuid
    );
end;
$$ language plpgsql volatile security definer;


-- Create a function to handle simple transaction insertion
create or replace function utils.simple_transactions_insert_fn() returns trigger as
$$
declare
    v_ledger_id             bigint;
    v_account_id            bigint;
    v_category_id           bigint;
    v_debit_account_id      bigint;
    v_credit_account_id     bigint;
    v_account_internal_type text;
    v_transaction_uuid      text;
    v_user_data             text := utils.get_user();
begin
    -- validate inputs early
    if NEW.amount <= 0 then
        raise exception 'Transaction amount must be positive: %', NEW.amount;
    end if;

    if NEW.type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', NEW.type;
    end if;

    -- get the ledger_id and validate ownership
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid
       and l.user_data = v_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', NEW.ledger_uuid;
    end if;

    -- find the account details in one query
    select a.id, a.internal_type
      into v_account_id, v_account_internal_type
      from data.accounts a
     where a.uuid = NEW.account_uuid
       and a.ledger_id = v_ledger_id
       and a.user_data = v_user_data;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger % for current user', 
                       NEW.account_uuid, NEW.ledger_uuid;
    end if;

    -- handle category lookup
    if NEW.category_uuid is null then
        -- find the "Unassigned" category directly
        select a.id into v_category_id
          from data.accounts a
         where a.ledger_id = v_ledger_id
           and a.user_data = v_user_data
           and a.name = 'Unassigned'
           and a.type = 'equity';
           
        if v_category_id is null then
            raise exception 'Could not find "Unassigned" category in ledger % for current user', 
                           NEW.ledger_uuid;
        end if;
    else
        -- find the specified category
        select a.id into v_category_id
          from data.accounts a
         where a.uuid = NEW.category_uuid 
           and a.ledger_id = v_ledger_id
           and a.user_data = v_user_data;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger % for current user', 
                           NEW.category_uuid, NEW.ledger_uuid;
        end if;
    end if;

    -- determine debit and credit accounts based on account type and transaction type
    case 
        when v_account_internal_type = 'asset_like' and NEW.type = 'inflow' then
            -- inflow to asset: debit asset (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        when v_account_internal_type = 'asset_like' and NEW.type = 'outflow' then
            -- outflow from asset: debit category (decrease), credit asset (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and NEW.type = 'inflow' then
            -- inflow to liability: debit category (decrease), credit liability (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and NEW.type = 'outflow' then
            -- outflow from liability: debit liability (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        else
            raise exception 'Unsupported combination: account_type=% and transaction_type=%', 
                           v_account_internal_type, NEW.type;
    end case;

    -- insert the transaction into the transactions table
    insert into data.transactions (
        description, 
        date, 
        amount, 
        debit_account_id, 
        credit_account_id, 
        ledger_id, 
        metadata,
        user_data
    )
    values (
        NEW.description,
        NEW.date,
        NEW.amount,
        v_debit_account_id,
        v_credit_account_id,
        v_ledger_id,
        NEW.metadata,
        v_user_data
    )
    returning uuid into v_transaction_uuid;

    -- Return the data for the new row
    -- The NEW record for an INSTEAD OF INSERT trigger should be populated with values
    -- that match the view's columns. PostgREST uses this to return the created resource.
    NEW.uuid := v_transaction_uuid;

    return NEW;
end;
$$ language plpgsql security definer;


-- Create a function to handle simple transaction updates
create or replace function utils.simple_transactions_update_fn() returns trigger as
$$
declare
    v_ledger_id             bigint;
    v_account_id            bigint;
    v_category_id           bigint;
    v_debit_account_id      bigint;
    v_credit_account_id     bigint;
    v_account_internal_type text;
    v_transaction_id        bigint;
    v_user_data             text := utils.get_user();
begin
    -- validate inputs early
    if NEW.amount <= 0 then
        raise exception 'Transaction amount must be positive: %', NEW.amount;
    end if;

    if NEW.type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', NEW.type;
    end if;

    -- get the transaction ID and verify ownership
    select t.id
      into v_transaction_id
      from data.transactions t
     where t.uuid = OLD.uuid
       and t.user_data = v_user_data;

    if v_transaction_id is null then
        raise exception 'Transaction with UUID % not found for current user', OLD.uuid;
    end if;

    -- get the ledger_id and validate ownership
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid
       and l.user_data = v_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', NEW.ledger_uuid;
    end if;

    -- find the account details in one query
    select a.id, a.internal_type
      into v_account_id, v_account_internal_type
      from data.accounts a
     where a.uuid = NEW.account_uuid
       and a.ledger_id = v_ledger_id
       and a.user_data = v_user_data;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger % for current user', 
                       NEW.account_uuid, NEW.ledger_uuid;
    end if;

    -- handle category lookup
    if NEW.category_uuid is null then
        -- find the "Unassigned" category directly
        select a.id into v_category_id
          from data.accounts a
         where a.ledger_id = v_ledger_id
           and a.user_data = v_user_data
           and a.name = 'Unassigned'
           and a.type = 'equity';
           
        if v_category_id is null then
            raise exception 'Could not find "Unassigned" category in ledger % for current user', 
                           NEW.ledger_uuid;
        end if;
    else
        -- find the specified category
        select a.id into v_category_id
          from data.accounts a
         where a.uuid = NEW.category_uuid 
           and a.ledger_id = v_ledger_id
           and a.user_data = v_user_data;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger % for current user', 
                           NEW.category_uuid, NEW.ledger_uuid;
        end if;
    end if;

    -- determine debit and credit accounts based on account type and transaction type
    case 
        when v_account_internal_type = 'asset_like' and NEW.type = 'inflow' then
            -- inflow to asset: debit asset (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        when v_account_internal_type = 'asset_like' and NEW.type = 'outflow' then
            -- outflow from asset: debit category (decrease), credit asset (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and NEW.type = 'inflow' then
            -- inflow to liability: debit category (decrease), credit liability (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and NEW.type = 'outflow' then
            -- outflow from liability: debit liability (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        else
            raise exception 'Unsupported combination: account_type=% and transaction_type=%', 
                           v_account_internal_type, NEW.type;
    end case;

    -- update the transaction in data.transactions
    update data.transactions
       set description = NEW.description,
           date = NEW.date,
           amount = NEW.amount,
           debit_account_id = v_debit_account_id,
           credit_account_id = v_credit_account_id,
           ledger_id = v_ledger_id,
           metadata = NEW.metadata,
           updated_at = current_timestamp
     where id = v_transaction_id;

    -- NEW already contains the updated fields from the view's perspective
    return NEW;
end;
$$ language plpgsql security definer;


-- Create a function to handle simple transaction deletions
create or replace function utils.simple_transactions_delete_fn() returns trigger as
$$
declare
    v_user_data text := utils.get_user();
    v_affected_rows int;
begin
    -- delete the transaction from data.transactions with user context validation
    delete from data.transactions
     where uuid = OLD.uuid
       and user_data = v_user_data
    returning 1 into v_affected_rows;
    
    -- verify the deletion was successful (row existed and belonged to user)
    if v_affected_rows is null or v_affected_rows = 0 then
        raise exception 'Transaction with UUID % not found for current user', OLD.uuid;
    end if;

    -- for INSTEAD OF DELETE, returning OLD is standard practice
    return OLD;
end;
$$ language plpgsql security definer;


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.add_transaction(text, timestamptz, text, text, bigint, text, text);
drop function if exists utils.assign_to_category(text, timestamptz, text, bigint, text, text) cascade;

-- RECREATE utils.transactions_insert_single_fn() IN THE DOWN MIGRATION
-- This function is used by the trigger on the original api.transactions view (manual double-entry)
-- which is recreated in the down migration of 20250506165235_add_transactions_triggers.sql.
create or replace function utils.transactions_insert_single_fn()
returns trigger as
$$
declare
    v_ledger_id         bigint;
    v_debit_account_id  bigint;
    v_credit_account_id bigint;
    v_user_data         text := utils.get_user();
begin
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid and l.user_data = v_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', NEW.ledger_uuid;
    end if;

    select a.id
      into v_debit_account_id
      from data.accounts a
     where a.uuid = NEW.debit_account_uuid
       and a.ledger_id = v_ledger_id and a.user_data = v_user_data;

    if v_debit_account_id is null then
        raise exception 'Debit account with UUID % not found in ledger % for current user', NEW.debit_account_uuid, NEW.ledger_uuid;
    end if;

    select a.id
      into v_credit_account_id
      from data.accounts a
     where a.uuid = NEW.credit_account_uuid
       and a.ledger_id = v_ledger_id and a.user_data = v_user_data;

    if v_credit_account_id is null then
        raise exception 'Credit account with UUID % not found in ledger % for current user', NEW.credit_account_uuid, NEW.ledger_uuid;
    end if;

    insert into data.transactions (
        description, date, amount,
        debit_account_id, credit_account_id, ledger_id,
        metadata
    )
    values (
        NEW.description, NEW.date, NEW.amount,
        v_debit_account_id, v_credit_account_id, v_ledger_id,
        NEW.metadata
    )
    returning uuid, description, amount, metadata, date into
        NEW.uuid, NEW.description, NEW.amount, NEW.metadata, NEW.date;
    
    -- NEW.ledger_uuid, NEW.debit_account_uuid, NEW.credit_account_uuid are already set from the input.
    return NEW;
end;
$$ language plpgsql volatile security definer;


drop function if exists utils.simple_transactions_insert_fn();
drop function if exists utils.simple_transactions_update_fn();
drop function if exists utils.simple_transactions_delete_fn();

-- +goose StatementEnd
