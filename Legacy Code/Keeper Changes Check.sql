DROP TABLE IF EXISTS lt_aug_kc;
CREATE TEMP TABLE lt_aug_kc (
    VIN varchar(50),
    VRM varchar(50)
);
INSERT INTO lt_aug_kc (VRM, VIN)
VALUES
('AE64TWV', 'WVWZZZ7NZFV012682'),
('AF15FCN', 'MMCJNKB40FD934495'),
(...,        ....)...
WITH dedupe AS (
    SELECT DISTINCT VRM,
            VIN
    FROM lt_aug_kc
)
SELECT la.agreement_code,
       dd.VRM,
       dd.VIN,
       cd.first_name,
       cd.last_name,
       lt.status_code,
       lt.capital_balance,
       lt.arrears,
       lt.days_in_arrears,
       ad.current_address__c
FROM dedupe AS dd
LEFT JOIN oodledata_loans.loan_agreements AS la
ON la.registration = dd.VRM
LEFT JOIN oodledata.customer_dim AS cd
ON cd.account_id = la.main_borrower_account_id
LEFT JOIN oodledata_loans.loan_timeline AS lt
ON lt.agreement_code = la.agreement_code AND date = '2020-09-15'
LEFT JOIN salesforce_realtime.account_defeed AS ad
ON ad.id = la.main_borrower_account_id
ORDER BY VRM ASC;
