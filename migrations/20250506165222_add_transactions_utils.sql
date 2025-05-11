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
    v_transaction_record data.transactions;
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
    -- using a CTE to avoid duplicate scans of the accounts table
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
    -- and get the full record in one operation
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
    ) returning * into v_transaction_record;

    -- return the full record matching the api.transactions view structure
    -- using a single VALUES expression is more efficient than a subquery
    return query
    values (
        v_transaction_record.uuid,  -- r_uuid
        p_description,              -- r_description
        p_amount,                   -- r_amount
        p_date,                     -- r_date
        v_transaction_record.metadata, -- r_metadata
        p_ledger_uuid,              -- r_ledger_uuid
        null::text,                 -- r_transaction_type (null for direct assignments)
        v_income_account_uuid,      -- r_account_uuid (using Income account)
        p_category_uuid             -- r_category_uuid
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
    v_category_uuid         text := NEW.category_uuid;
begin
    -- validate inputs early for fast failure
    if NEW.amount <= 0 then
        raise exception 'Transaction amount must be positive: %', NEW.amount;
    end if;

    if NEW.type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', NEW.type;
    end if;

    -- get the ledger_id and validate ownership in one query
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

    -- handle category lookup with a more efficient approach
    if v_category_uuid is null then
        -- Use a direct query to find the "Unassigned" category
        select a.id, a.uuid into v_category_id, v_category_uuid
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
         where a.uuid = v_category_uuid 
           and a.ledger_id = v_ledger_id
           and a.user_data = v_user_data;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger % for current user', 
                           v_category_uuid, NEW.ledger_uuid;
        end if;
    end if;

    -- determine debit and credit accounts based on account type and transaction type
    -- using a more readable CASE expression
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

    -- insert the transaction into the transactions table with all necessary fields
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

    -- Populate the NEW record with all necessary fields for the view
    NEW.uuid := v_transaction_uuid;
    -- The other fields are already set in NEW from the INSERT statement
    -- If category_uuid was null and we found Unassigned, update it
    if NEW.category_uuid is null then
        NEW.category_uuid := v_category_uuid;
    end if;

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
    v_category_uuid         text := NEW.category_uuid;
    v_transaction_record    data.transactions;
begin
    -- Validate inputs early for fast failure
    if NEW.amount <= 0 then
        raise exception 'Transaction amount must be positive: %', NEW.amount;
    end if;

    if NEW.type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', NEW.type;
    end if;

    -- Get the transaction record and verify ownership in one query
    select t.* into v_transaction_record
      from data.transactions t
     where t.uuid = OLD.uuid
       and t.user_data = v_user_data;

    if v_transaction_record.id is null then
        raise exception 'Transaction with UUID % not found for current user', OLD.uuid;
    end if;
    
    v_transaction_id := v_transaction_record.id;

    -- Get the ledger_id and validate ownership
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid
       and l.user_data = v_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', NEW.ledger_uuid;
    end if;

    -- Find the account details in one query
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

    -- Handle category lookup with a more efficient approach
    if v_category_uuid is null then
        -- Use a direct query to find the "Unassigned" category
        select a.id, a.uuid into v_category_id, v_category_uuid
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
        -- Find the specified category
        select a.id into v_category_id
          from data.accounts a
         where a.uuid = v_category_uuid 
           and a.ledger_id = v_ledger_id
           and a.user_data = v_user_data;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger % for current user', 
                           v_category_uuid, NEW.ledger_uuid;
        end if;
    end if;

    -- Determine debit and credit accounts based on account type and transaction type
    -- Using a more readable CASE expression
    case 
        when v_account_internal_type = 'asset_like' and NEW.type = 'inflow' then
            -- Inflow to asset: debit asset (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        when v_account_internal_type = 'asset_like' and NEW.type = 'outflow' then
            -- Outflow from asset: debit category (decrease), credit asset (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and NEW.type = 'inflow' then
            -- Inflow to liability: debit category (decrease), credit liability (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and NEW.type = 'outflow' then
            -- Outflow from liability: debit liability (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        else
            raise exception 'Unsupported combination: account_type=% and transaction_type=%', 
                           v_account_internal_type, NEW.type;
    end case;

    -- Update the transaction in data.transactions
    update data.transactions
       set description = NEW.description,
           date = NEW.date,
           amount = NEW.amount,
           debit_account_id = v_debit_account_id,
           credit_account_id = v_credit_account_id,
           ledger_id = v_ledger_id,
           metadata = NEW.metadata,
           updated_at = current_timestamp
     where id = v_transaction_id
     returning * into v_transaction_record;

    -- Populate the NEW record with values from the updated transaction
    NEW.uuid := v_transaction_record.uuid;
    -- If category_uuid was null and we found Unassigned, update it
    if NEW.category_uuid is null then
        NEW.category_uuid := v_category_uuid;
    end if;

    return NEW;
end;
$$ language plpgsql security definer;


-- Create a function to handle simple transaction deletions
create or replace function utils.simple_transactions_delete_fn() returns trigger as
$$
declare
    v_user_data text := utils.get_user();
    v_transaction_record data.transactions;
begin
    -- Get the transaction record and verify ownership in one query
    select * into v_transaction_record
    from data.transactions t
    where t.uuid = OLD.uuid
      and t.user_data = v_user_data;
    
    if v_transaction_record.id is null then
        raise exception 'Transaction with UUID % not found for current user', OLD.uuid;
    end if;
    
    -- Perform soft delete by setting deleted_at
    update data.transactions
    set deleted_at = current_timestamp
    where uuid = OLD.uuid and user_data = v_user_data
    returning * into v_transaction_record;
    
    -- Verify the update was successful
    if v_transaction_record.deleted_at is null then
        raise exception 'Failed to soft-delete transaction with UUID %', OLD.uuid;
    end if;
    
    return OLD;
end;
$$ language plpgsql volatile security definer;



-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.add_transaction(text, timestamptz, text, text, bigint, text, text);
drop function if exists utils.assign_to_category(text, timestamptz, text, bigint, text, text) cascade;
drop function if exists utils.get_budget_status(text, text) cascade;
drop function if exists api.get_budget_status(text) cascade;

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
