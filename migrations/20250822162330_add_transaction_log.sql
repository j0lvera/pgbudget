-- +goose Up
-- +goose StatementBegin

-- track all transaction corrections and deletions for audit trail
create table data.transaction_log
(
    id bigint generated always as identity,
    original_transaction_id bigint not null,
    reversal_transaction_id bigint,
    correction_transaction_id bigint,
    mutation_type text not null,
    reason text,
    created_at timestamptz not null default current_timestamp,
    user_data text not null default utils.get_user(),

    constraint transaction_log_id_pk primary key (id),
    constraint transaction_log_original_transaction_id_fk foreign key (original_transaction_id) references data.transactions(id),
    constraint transaction_log_reversal_transaction_id_fk foreign key (reversal_transaction_id) references data.transactions(id),
    constraint transaction_log_correction_transaction_id_fk foreign key (correction_transaction_id) references data.transactions(id),
    constraint transaction_log_mutation_type_check check (mutation_type in ('correction', 'deletion'))
);

-- index for querying transaction history by original transaction
create index idx_transaction_log_original_id on data.transaction_log(original_transaction_id);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop table if exists data.transaction_log;

-- +goose StatementEnd
