-- File: _ledgers_utils.sql
-- Purpose: Defines utility functions specific to ledger management,
--          callable by other utils or api functions.

-- Currently, no ledger-specific utility functions (that are not trigger functions
-- or direct API view/function support) have been identified from the existing
-- ledger-related migrations (20250326192940, 20250326194640, 20250503172238).
-- General utilities like utils.get_user() or utils.nanoid() are defined elsewhere.
-- This file serves as a placeholder for future ledger-related utility functions.

-- Example of a potential future utility function:
/*
create or replace function utils.internal_get_ledger_id_by_uuid(
    p_ledger_uuid text,
    p_user_data text default utils.get_user() -- Ensure user context
) returns bigint as $$
declare
  v_ledger_id bigint;
begin
  select id into v_ledger_id from data.ledgers
  where uuid = p_ledger_uuid and user_data = p_user_data;

  if not found then
    raise exception 'Ledger with UUID % not found for current user.', p_ledger_uuid;
  end if;
  return v_ledger_id;
end;
$$ language plpgsql stable security definer;

comment on function utils.internal_get_ledger_id_by_uuid(text, text) is 'Internal utility to safely retrieve a ledger''s internal ID from its UUID, ensuring it belongs to the current user.';
*/
