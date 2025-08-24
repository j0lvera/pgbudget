-- +goose Up
-- +goose StatementBegin

-- enhanced error handling utilities and improvements
-- following postgresql conventions with lowercase sql and comments above each step

-- create error handling utility functions in utils schema
-- standardize constraint violation messages with user-friendly text
create or replace function utils.handle_constraint_violation(
    p_constraint_name text,
    p_table_name text,
    p_column_value text default null
) returns text as $$
begin
    -- handle unique constraint violations with user-friendly messages
    case p_constraint_name
        when 'ledgers_name_user_unique' then
            return format('A ledger named "%s" already exists. Please choose a different name.', p_column_value);
        when 'accounts_name_ledger_unique' then
            return format('An account named "%s" already exists in this ledger. Please choose a different name.', p_column_value);
        when 'ledgers_uuid_unique' then
            return 'Ledger UUID conflict detected. Please try again.';
        when 'accounts_uuid_unique' then
            return 'Account UUID conflict detected. Please try again.';
        when 'transactions_uuid_unique' then
            return 'Transaction UUID conflict detected. Please try again.';
        when 'balance_snapshots_account_transaction_unique' then
            return 'Balance snapshot already exists for this transaction.';
        else
            -- fallback for unknown constraints
            return format('Duplicate entry detected for %s. Please check your input and try again.', coalesce(p_table_name, 'record'));
    end case;
end;
$$ language plpgsql immutable;

-- create transaction validation utility function
-- validate transaction amounts, dates, and business rules
create or replace function utils.validate_transaction_data(
    p_amount bigint,
    p_date timestamptz,
    p_type text default null
) returns void as $$
begin
    -- validate amount is positive
    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive. Received: $%.%', 
            p_amount / 100, lpad((p_amount % 100)::text, 2, '0');
    end if;
    
    -- validate amount is reasonable (less than $1 million)
    if p_amount > 100000000 then -- $1,000,000.00 in cents
        raise exception 'Transaction amount exceeds maximum limit of $1,000,000.00. Received: $%.%',
            p_amount / 100, lpad((p_amount % 100)::text, 2, '0');
    end if;
    
    -- validate date is not too far in the future (more than 1 year)
    if p_date > current_timestamp + interval '1 year' then
        raise exception 'Transaction date cannot be more than 1 year in the future. Received: %', 
            p_date::date;
    end if;
    
    -- validate date is not too far in the past (more than 10 years)
    if p_date < current_timestamp - interval '10 years' then
        raise exception 'Transaction date cannot be more than 10 years in the past. Received: %', 
            p_date::date;
    end if;
    
    -- validate transaction type if provided
    if p_type is not null and p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: "%". Must be either "inflow" or "outflow".', p_type;
    end if;
end;
$$ language plpgsql immutable;

-- create input validation utility function
-- validate common input parameters like names, descriptions
create or replace function utils.validate_input_data(
    p_name text default null,
    p_description text default null,
    p_field_name text default 'field'
) returns text as $$
declare
    v_cleaned_name text;
begin
    -- validate and clean name if provided
    if p_name is not null then
        -- trim whitespace
        v_cleaned_name := trim(p_name);
        
        -- check if empty after trimming
        if v_cleaned_name = '' then
            raise exception '% name cannot be empty or contain only whitespace.', initcap(p_field_name);
        end if;
        
        -- check length constraints
        if char_length(v_cleaned_name) > 255 then
            raise exception '% name cannot exceed 255 characters. Current length: %', 
                initcap(p_field_name), char_length(v_cleaned_name);
        end if;
        
        -- check for invalid characters (basic validation)
        if v_cleaned_name ~ '[<>"\\/]' then
            raise exception '% name contains invalid characters. Please avoid: < > " \ /', 
                initcap(p_field_name);
        end if;
        
        return v_cleaned_name;
    end if;
    
    -- validate description length if provided
    if p_description is not null and char_length(p_description) > 1000 then
        raise exception 'Description cannot exceed 1000 characters. Current length: %', 
            char_length(p_description);
    end if;
    
    return p_name;
end;
$$ language plpgsql immutable;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- remove enhanced error handling utilities
drop function if exists utils.validate_input_data(text, text, text);
drop function if exists utils.validate_transaction_data(bigint, timestamptz, text);
drop function if exists utils.handle_constraint_violation(text, text, text);

-- +goose StatementEnd
