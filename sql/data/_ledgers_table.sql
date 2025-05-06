-- File: _ledgers_table.sql
-- Purpose: Defines the core data.ledgers table, its constraints, RLS policies, and updated_at trigger.
-- Source: migrations/20250326192940_add_ledgers_table.sql

-- (Assumes utils.nanoid(), utils.get_user(), and utils.set_updated_at_fn() are defined in preceding migrations/setup)

create table data.ledgers
(
    id          bigint generated always as identity primary key,
    uuid        text        not null default utils.nanoid(8),

    created_at  timestamptz not null default current_timestamp,
    updated_at  timestamptz not null default current_timestamp,

    name        text        not null,
    description text,
    metadata    jsonb,

    user_data   text        not null default utils.get_user(),

    constraint ledgers_uuid_unique unique (uuid),
    constraint ledgers_name_user_unique unique (name, user_data),
    constraint ledgers_name_length_check check (char_length(name) <= 255),
    constraint ledgers_user_data_length_check check (char_length(user_data) <= 255),
    constraint ledgers_description_length_check check (char_length(description) <= 255)
);

comment on table data.ledgers is 'Stores ledger information for users, representing their overall budget.';
comment on column data.ledgers.uuid is 'Public unique identifier for the ledger.';
comment on column data.ledgers.name is 'User-defined name for the ledger.';
comment on column data.ledgers.description is 'Optional description for the ledger.';
comment on column data.ledgers.metadata is 'Optional JSONB field for storing arbitrary structured data related to the ledger.';
comment on column data.ledgers.user_data is 'Identifier of the user who owns the ledger, typically from JWT.';
comment on column data.ledgers.created_at is 'Timestamp of when the ledger was created.';
comment on column data.ledgers.updated_at is 'Timestamp of when the ledger was last updated.';

create trigger ledgers_updated_at_tg
    before update
    on data.ledgers
    for each row
execute procedure utils.set_updated_at_fn();

comment on trigger ledgers_updated_at_tg on data.ledgers is 'Automatically updates the updated_at timestamp before any update operation on a ledger.';

-- allow authenticated user to access the ledgers table.
grant all on data.ledgers to pgb_web_user;
grant usage, select on sequence data.ledgers_id_seq to pgb_web_user;

-- enable RLS
alter table data.ledgers
    enable row level security;

create policy ledgers_policy on data.ledgers
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

comment on policy ledgers_policy on data.ledgers is 'Ensures that users can only access and modify their own ledgers based on the user_data column.';
