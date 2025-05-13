-- +goose Up
-- +goose StatementBegin

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

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop policy if exists ledgers_policy on data.ledgers;

revoke all on data.ledgers from pgb_web_user;

drop table data.ledgers;

-- +goose StatementEnd
