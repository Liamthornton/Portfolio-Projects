-- Forbearances Table --
DROP TABLE IF EXISTS forbearances;
CREATE temp TABLE forbearances as (
    SELECT agreement_code                                                                                               as agreement_code,
           min(case when f.type in ('Retrospective Payment Holiday','Payment Holiday')
                    and f.status in ('Agreed','Expired')
                    and f.booking_status in ('Completed','Reviewed')
                    then created_date::date
               end)                                                                                                     as ph_created_date,
           min(case when f.type in ('Retrospective Payment Holiday','Payment Holiday')
                    and f.status in ('Agreed','Expired')
                    and f.booking_status in ('Completed','Reviewed')
                    then start_date::date
               end)                                                                                                     as ph_start_date,
           max(case when f.type in ('Retrospective Payment Holiday','Payment Holiday')
                    and f.status in ('Agreed','Expired')
                    and f.booking_status in ('Completed','Reviewed')
                    then end_date::date
               end)                                                                                                     as ph_end_date,
           min(case when f.type in ('Payment Reduction')
                    and f.status in ('Agreed','Expired')
                    and f.booking_status in ('Completed','Reviewed')
                    then created_date::Date
               end)                                                                                                     as rmp_created_date,
           min(case when f.type in ('Payment Reduction')
                    and f.status in ('Agreed','Expired')
                    and f.booking_status in ('Completed','Reviewed')
                    then start_date::date
               end)                                                                                                     as rmp_start_date,
           max(case when f.type in ('Payment Reduction')
                    and f.status in ('Agreed','Expired')
                    and f.booking_status in ('Completed','Reviewed')
                    then end_date::date
               end)                                                                                                     as rmp_end_date,
           min(case when f.type ='Additional Payment Holiday'
                    and f.status in ('Agreed', 'Expired')
                    and f.booking_status in ('Completed', 'Reviewed')
                    then start_date::date
               end)                                                                                                     as add_ph_start_date,
           max(case when f.type ='Additional Payment Holiday'
                    and f.status in ('Agreed', 'Expired')
                    and f.booking_status in ('Completed', 'Reviewed')
                    then end_date::date
               end)                                                                                                     as add_ph_end_date,
           least(greatest(ph_start_date, ph_created_date),greatest(rmp_start_date, rmp_created_date))                   as first_fb_start_date,
           least(ph_end_date,rmp_end_date)                                                                              as first_fb_end_date
    FROM oodledata.forbearance as f
    GROUP BY 1);
SELECT *
FROM forbearances;

-- Arrears Status' --
DROP TABLE IF EXISTS arrears;
CREATE TEMP TABLE arrears as (
with pre_ph_arr as (
    SELECT f.agreement_code,
           CASE
               WHEN payment_reduction_adjusted_arrears_status = 'Up-to-Date' then -1
               WHEN payment_reduction_adjusted_arrears_status = '0-Down' then 0
               WHEN payment_reduction_adjusted_arrears_status = '1-Down' then 1
               WHEN payment_reduction_adjusted_arrears_status = '2-Down' then 2
               WHEN payment_reduction_adjusted_arrears_status = '3-Down' then 3
               WHEN payment_reduction_adjusted_arrears_status = '4-Down' then 4
               WHEN payment_reduction_adjusted_arrears_status = '5+ Down' then 5
               ELSE null
               END as pre_arr
    FROM forbearances as f
    LEFT JOIN oodledata_loans.loan_timeline as lt
        ON lt.agreement_code = f.agreement_code and lt.date = f.first_fb_start_date
),
     june_onward_arr as (
    SELECT f.agreement_code,
           date_part('month', lt.date) arr_month,
            CASE
               WHEN payment_reduction_adjusted_arrears_status = 'Up-to-Date' then -1
               WHEN payment_reduction_adjusted_arrears_status = '0-Down' then 0
               WHEN payment_reduction_adjusted_arrears_status = '1-Down' then 1
               WHEN payment_reduction_adjusted_arrears_status = '2-Down' then 2
               WHEN payment_reduction_adjusted_arrears_status = '3-Down' then 3
               WHEN payment_reduction_adjusted_arrears_status = '4-Down' then 4
               WHEN payment_reduction_adjusted_arrears_status = '5+ Down' then 5
               ELSE null
           END as arr_status
    FROM forbearances as f
    LEFT JOIN oodledata_loans.loan_timeline as lt
        ON lt.agreement_code = f.agreement_code
    WHERE date IN (
        SELECT last_day(lt.date)
        FROM oodledata_loans.loan_timeline as lt
        WHERE lt.date between '2020-06-30' and '2020-11-30'
        )
    GROUP BY 1,2,3
),
     post_ph_arr as (
    SELECT agreement_code,
           SUM(case when arr_month = 6 then arr_status END) as jun_arr,
           SUM(case when arr_month = 7 then arr_status END) as jul_arr,
           SUM(case when arr_month = 8 then arr_status END) as aug_arr,
           SUM(case when arr_month = 9 then arr_status END) as sep_arr,
           SUM(case when arr_month = 10 then arr_status END) as oct_arr,
           SUM(case when arr_month = 11 then arr_status END) as nov_arr
    FROM june_onward_arr as joa
    GROUP BY 1
)
-- TABLE DEFINITION --
SELECT bph.agreement_code,
       pre_arr,
       jun_arr,
       jul_arr,
       aug_arr,
       sep_arr,
       oct_arr,
       nov_arr
FROM forbearances as f
LEFT JOIN pre_ph_arr as bph
    ON bph.agreement_code = f.agreement_code
LEFT JOIN post_ph_arr as aph
    ON aph.agreement_code = f.agreement_code);


-- Settlements and Defaults --
DROP TABLE IF EXISTS sets_defs;
CREATE TEMP TABLE sets_defs as (
    with cases as (
        SELECT f.agreement_code,
               type,
               MIN(date) as sd_date
        FROM forbearances as f
        LEFT JOIN oodledata_loans.settlements_and_defaults as sd
            ON sd.agreement_code = f.agreement_code
        WHERE type IN ('VT - Default', 'Default', 'VT', 'Settlement')
        GROUP BY 1, 2
    )
    SELECT cases.agreement_code,
           type,
           sd_date,
           capital_balance as sd_balance
    FROM cases
    LEFT JOIN oodledata_loans.loan_timeline as lt
        ON lt.agreement_code = cases.agreement_code and lt.date = date_add('days',-1, cases.sd_date)
);
SELECT *
FROM sets_defs;

-- Balances --
DROP TABLE IF EXISTS balances;
CREATE TEMP TABLE balances as (
with balances as (
    SELECT agreement_code,
           date_part('month',date) as month,
           capital_balance
    FROM oodledata_loans.loan_timeline
    WHERE date IN (
                   SELECT last_day(date)
                   FROM oodledata_loans.loan_timeline
                   WHERE date BETWEEN '2020-06-30' AND '2020-11-30'
                  )
    AND agreement_code IN (
                   SELECT agreement_code
                   FROM forbearances
                   )
)
SELECT agreement_code,
       sum(CASE WHEN month = 6 THEN capital_balance END) as jun_bal,
       sum(CASE WHEN month = 7 THEN capital_balance END) as jul_bal,
       sum(CASE WHEN month = 8 THEN capital_balance END) as aug_bal,
       sum(CASE WHEN month = 9 THEN capital_balance END) as sept_bal,
       sum(CASE WHEN month = 10 THEN capital_balance END) as oct_bal,
       sum(CASE WHEN month = 11 THEN capital_balance END) as nov_bal
FROM balances as bal
GROUP BY 1);

-- Final Table Definition --
DROP TABLE IF EXISTS PBL;
CREATE TEMP TABLE PBL as (
    SELECT f.agreement_code,
           f.first_fb_start_date,
           f.first_fb_end_date,
           f.rmp_start_date,
           f.rmp_end_date,
           f.add_ph_end_date,
           f.add_ph_start_date,
           arr.pre_arr,
           arr.jun_arr,
           arr.jul_arr,
           arr.aug_arr,
           arr.sep_arr,
           arr.oct_arr,
           arr.nov_arr,
           sd.type,
           sd.sd_date,
           sd.sd_balance,
           bal.jun_bal,
           bal.jul_bal,
           bal.aug_bal,
           bal.sept_bal,
           bal.oct_bal,
           bal.nov_bal
    FROM forbearances as f
        LEFT JOIN arrears as arr
            ON arr.agreement_code = f.agreement_code
        LEFT JOIN sets_defs as sd
            ON sd.agreement_code = f.agreement_code
        LEFT JOIN balances as bal
            ON bal.agreement_code = f.agreement_code
);
SELECT *
FROM pbl;

-- MONTHLY REPORT --
SELECT SUM(case when first_fb_start_date <= '2020-06-30' THEN 1 ELSE 0 END)             as vol_ph,
       SUM(case when first_fb_start_date <= '2020-06-30' THEN greatest(jun_bal, sd_balance) ELSE 0 END)       as val_ph,
       SUM(case when first_fb_start_date <= '2020-06-30' AND
                     first_fb_end_date > '2020-06-30' AND
                     (sd_date > '2020-06-30' or sd_date IS NULL)
                THEN 1
                ELSE 0
           END)                                                               as vol_first_ph,
       SUM(case when first_fb_start_date <= '2020-06-30' AND
                     first_fb_end_date > '2020-06-30' AND
                     (sd_date > '2020-06-30' or sd_date IS NULL)
                THEN jun_bal
                ELSE 0
           END)                                                               as val_first_ph,
       SUM(case when first_fb_end_date <= '2020-06-30' AND
                     (add_ph_start_date notnull or (rmp_start_date != first_fb_start_date AND rmp_start_date notnull)) AND
                     (add_ph_start_date <= '2020-06-30' or rmp_start_date <= '2020-06-30') AND
                     (add_ph_end_date > '2020-06-30' or rmp_end_date > '2020-06-30') AND
                     (sd_date > '2020-06-30' or sd_date IS NULL)
                THEN 1
                ELSE 0
           END)                                                               as vol_ext_ph,
       SUM(case when first_fb_end_date <= '2020-06-30' AND
                     (add_ph_start_date notnull or (rmp_start_date != first_fb_start_date AND rmp_start_date notnull)) AND
                     (add_ph_start_date <= '2020-06-30' or rmp_start_date <= '2020-06-30') AND
                     (add_ph_end_date > '2020-06-30' or rmp_end_date > '2020-06-30') AND
                     (sd_date > '2020-06-30' or sd_date IS NULL)
                THEN jun_bal
                ELSE 0
           END)                                                               as val_ext_ph,
       SUM(case when (greatest(first_fb_end_date, add_ph_end_date, rmp_end_date) <= '2020-06-30') AND
                     (sd_date is NULL or sd_date > '2020-06-30') AND
                     pre_arr >= jun_arr
                THEN 1
                ELSE 0
           END)                                                               AS vol_perf,
       SUM(case when(greatest(first_fb_end_date, add_ph_end_date, rmp_end_date) <= '2020-06-30') AND
                     (sd_date is NULL or sd_date > '2020-06-30') AND
                     pre_arr >= jun_arr
                THEN jun_bal
                ELSE 0
           END)                                                               AS val_perf,
       SUM(case when (greatest(first_fb_end_date, add_ph_end_date, rmp_end_date) <= '2020-06-30') AND
                     (sd_date is NULL or sd_date > '2020-06-30') AND
                     pre_arr < jun_arr
                THEN 1
                ELSE 0
           END)                                                               AS vol_notperf,
       SUM(case when (greatest(first_fb_end_date, add_ph_end_date, rmp_end_date) <= '2020-06-30') AND
                     (sd_date is NULL or sd_date > '2020-06-30') AND
                     pre_arr < jun_arr
                THEN jun_bal
                ELSE 0
           END)                                                               AS val_notperf,
       SUM(case when type IN ('Default', 'VT - Default', 'VT') AND
                     sd_date <= '2020-06-30' and
                     sd_date notnull
                THEN 1
                ELSE 0
           END)                                                               AS  vol_def,
       SUM(case when type IN ('Default', 'VT - Default', 'VT') AND
                     sd_date <= '2020-06-30' and
                     sd_date notnull
                THEN sd_balance
                ELSE 0
           END)                                                               AS  val_def,
       SUM(case when type = 'Settlement' AND
                     sd_date <= '2020-06-30' AND
                     sd_date NOTNULL
                THEN 1
                ELSE 0
           END)                                                               AS vol_set,
       SUM(case when type = 'Settlement' AND
                     sd_date <= '2020-06-30' AND
                     sd_date NOTNULL
                THEN sd_balance
                ELSE 0
           END)                                                               AS val_set
FROM PBL;
