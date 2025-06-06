-- +goose Up
-- +goose StatementBegin

create table data.accounts
(
    id            bigint generated always as identity primary key,
    uuid          text        not null default utils.nanoid(8),

    created_at    timestamptz not null default current_timestamp,
    updated_at    timestamptz not null default current_timestamp,

    name          text        not null,
    description   text,
    type          text        not null,
    internal_type text        not null,
    metadata      jsonb,
    user_data     text        not null default utils.get_user(),

    -- fks
    ledger_id     bigint      not null references data.ledgers (id) on delete cascade,

    constraint accounts_uuid_unique unique (uuid),
    constraint accounts_name_unique unique (name, ledger_id),
    constraint accounts_name_length_check check (char_length(name) <= 255),
    constraint accounts_user_data_length_check check (char_length(user_data) <= 255),
    constraint accounts_description_length_check check (char_length(description) <= 255),
    constraint accounts_type_check check (
        type in ('asset', 'liability', 'equity', 'revenue', 'expense')
        ),
    constraint accounts_internal_type_check check (
        (type = 'asset' and internal_type = 'asset_like') or
        (type = 'expenses' and internal_type = 'asset_like') or
        (type = 'liability' and internal_type = 'liability_like') or
        (type = 'equity' and internal_type = 'liability_like') or
        (type = 'revenue' and internal_type = 'liability_like')
        )
);

create trigger accounts_updated_at_tg
    before update
    on data.accounts
    for each row
execute procedure utils.set_updated_at_fn();

-- create a trigger function to set internal_type based on account type
create or replace function utils.set_account_internal_type_fn()
    returns trigger as
$$
begin
    -- determine internal type based on account type
    if new.type = 'asset' or new.type = 'expense' then
        new.internal_type := 'asset_like';
    else
        new.internal_type := 'liability_like';
    end if;

    return new;
end;
$$ language plpgsql;

-- create a trigger to automatically set internal_type before insert
create trigger accounts_set_internal_type_tg
    before insert
    on data.accounts
    for each row
execute procedure utils.set_account_internal_type_fn();

-- allow authenticated user to access the accounts table.
grant all on data.accounts to pgb_web_user;
grant usage, select on sequence data.accounts_id_seq to pgb_web_user;

-- enable RLS
alter table data.accounts
    enable row level security;

create policy accounts_policy on data.accounts
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop policy if exists accounts_policy on data.accounts;

revoke all on data.accounts from pgb_web_user;

drop trigger if exists accounts_updated_at_tg on data.accounts;
drop trigger if exists accounts_set_internal_type_tg on data.accounts;
drop function if exists utils.set_account_internal_type_fn();

drop table data.accounts;

-- +goose StatementEnd
