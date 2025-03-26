-- +goose Up
-- +goose StatementBegin
CREATE OR REPLACE VIEW data.account_balances AS
SELECT 
    a.name AS account_name,
    COALESCE(
        (SELECT SUM(
            CASE 
                WHEN t.credit_account_id = a.id THEN t.amount 
                WHEN t.debit_account_id = a.id THEN -t.amount 
                ELSE 0 
            END
        ) FROM data.transactions t
        WHERE t.credit_account_id = a.id OR t.debit_account_id = a.id),
        0
    ) AS balance,
    COALESCE(
        (SELECT SUM(
            CASE 
                WHEN t.credit_account_id = a.id THEN t.amount 
                WHEN t.debit_account_id = a.id THEN -t.amount 
                ELSE 0 
            END
        ) FROM data.transactions t
        JOIN data.accounts credit_acc ON t.credit_account_id = credit_acc.id
        JOIN data.accounts debit_acc ON t.debit_account_id = debit_acc.id
        WHERE (t.credit_account_id = a.id OR t.debit_account_id = a.id)
          AND (credit_acc.type IN ('asset', 'liability') OR debit_acc.type IN ('asset', 'liability'))),
        0
    ) AS activity
FROM 
    data.accounts a
ORDER BY 
    a.name;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP VIEW IF EXISTS data.account_balances;
-- +goose StatementEnd
