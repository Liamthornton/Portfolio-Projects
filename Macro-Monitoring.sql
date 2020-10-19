DROP TABLE IF EXISTS portfolio;
CREATE TEMP TABLE portfolio as (
    with live_loans as (
        SELECT lt.agreement_code,
               status_code,
               capital_balance,
               days_in_arrears,
               arrears,
               arrears_status,
               arrears_status_last_payment_date,
               march_status.mar_arr_stat,
               march_status.mar_arr_num,
               case
                   when arrears_status = 'Up-to-Date' then 0
                   when arrears_status IN ('0-Down', '1-Down') then 1
                   when arrears_status = '2-Down' then 2
                   when arrears_status = '3-Down' then 3
                   when arrears_status = '4-Down' then 4
                   when arrears_status = '5+ Down' then 5
                   else null end as arr_num,
               case
                   when arrears_status_last_payment_date = 'Up-to-Date' then 0
                   when arrears_status_last_payment_date IN ('0-Down', '1-Down') then 1
                   when arrears_status_last_payment_date = '2-Down' then 2
                   when arrears_status_last_payment_date = '3-Down' then 3
                   when arrears_status_last_payment_date = '4-Down' then 4
                   when arrears_status_last_payment_date = '5+ Down' then 5
                   else null end as pre_arr_num
        FROM oodledata_loans.loan_timeline as lt
        LEFT JOIN (SELECT agreement_code,
                          arrears_status as mar_arr_stat,
                          case
                            when arrears_status = 'Up-to-Date' then 0
                            when arrears_status IN ('0-Down', '1-Down') then 1
                            when arrears_status = '2-Down' then 2
                            when arrears_status = '3-Down' then 3
                            when arrears_status = '4-Down' then 4
                            when arrears_status = '5+ Down' then 5
                          else null end as mar_arr_num
                    from oodledata_loans.loan_timeline
                    where date = '2020-03-08' and is_live) as march_status
        ON march_status.agreement_code = lt.agreement_code
        WHERE is_live
        AND date = '2020-10-17'
    ),
         covid_cases as (
             select agreement_code,
                    max(employment_industry) as industry,
                    max(employment_impact)   as cv_impact
             from oodledata.covid_cases
             group by 1
         )
    SELECT ll.*,
           cd.account_id,
           (2020- cast(cd.birth_year as int)) as age_yr,
           cd.is_with_shoosmiths,
           cd.region,
           cd.employment_status,
           cd.total_months_of_forbearance,
           cd.had_covid_ph,
           cd.is_vulnerable,
           cc.industry,
           cc.cv_impact
    from live_loans as ll
             left join oodledata_loans.loan_agreements as la
                       on la.agreement_code = ll.agreement_code
             left join oodledata.customer_dim as cd
                       on cd.account_id = la.main_borrower_account_id
             left join covid_cases as cc
                       on cc.agreement_code = ll.agreement_code
);
SELECT sum(capital_balance)
FROM portfolio
LIMIT 250;


-- Regional Data --
with grab_avg as(
SELECT region,
       count(distinct agreement_code) as cust,
       sum(capital_balance) as portfolio_bal,
       sum(case when had_covid_ph then 1 else 0 end) as covid,
       sum(case when had_covid_ph then capital_balance else 0 end) as covid_bal,
       sum(case when arr_num > mar_arr_num then 1 else 0 end) as det_vol,
       sum(case when arr_num > mar_arr_num then capital_balance else 0 end) as det_bal,
       sum(case when arrears_status = mar_arr_stat then 1 else 0 end) as hold_vol,
       sum(case when arrears_status = mar_arr_stat then capital_balance else 0 end) as hold_bal,
       sum(case when arr_num < mar_arr_num then 1 else 0 end) as imp_vol,
       sum(case when arr_num < mar_arr_num then capital_balance else 0 end) as imp_bal,
       sum(case when had_covid_ph and arr_num > mar_arr_num then 1 else 0 end) as det_cv_vol,
       sum(case when had_covid_ph and arr_num > mar_arr_num then capital_balance else 0 end) as det_cv_bal,
       sum(case when had_covid_ph and arrears_status = mar_arr_stat then 1 else 0 end) as hold_cv_vol,
       sum(case when had_covid_ph and arrears_status = mar_arr_stat then capital_balance else 0 end) as hold_cv_bal,
       sum(case when had_covid_ph and arr_num < mar_arr_num then 1 else 0 end) as imp_cv_vol,
       sum(case when had_covid_ph and arr_num < mar_arr_num then capital_balance else 0 end) as imp_cv_bal,
       covid_bal/portfolio_bal as cv_exp,
       det_bal/portfolio_bal as per_det,
       hold_bal/portfolio_bal as per_held,
       imp_bal/portfolio_bal as per_imp,
       det_cv_bal/covid_bal as per_cv_det,
       hold_cv_bal/covid_bal as per_cv_held,
       imp_cv_bal/covid_bal as per_cv_imp
FROM portfolio
group by 1)
SELECT avg(per_det) as avg_det,
       avg(per_held) as avg_held,
       avg(per_imp) as avg_imp,
       avg(per_cv_det) as avg_cv_det,
       avg(per_cv_held) as avg_cv_held,
       avg(per_cv_imp) as avg_cv_imp,
       avg(cv_exp)
FROM grab_avg;

SELECT region,
       arr_num,
       sum(capital_balance) as total_cb,
       sum(case when not had_covid_ph then capital_balance else 0 end) as non_cv_cb,
       sum(case when had_covid_ph then capital_balance else 0 end) as cv_bal
FROM portfolio
Group by 1, 2
ORDER BY 2 ASC;


-- Age-Based Exposures --
Drop table if exists grouped_age;
CREATE TEMP TABLE grouped_age as (
with age_buckets as (
    SELECT portfolio.*,
           case
               when age_yr BETWEEN 16 AND 24 then '16-24'
               when age_yr BETWEEN 25 AND 34 then '25-34'
               when age_yr BETWEEN 35 AND 49 then '35-49'
               when age_yr >= 50 then '50+'
               else 'Unknown'
           end as age_group
    FROM portfolio
)
SELECT age_group,
       count(distinct agreement_code) as cust,
       sum(capital_balance) as portfolio_bal,
       sum(case when had_covid_ph then 1 else 0 end) as covid,
       sum(case when had_covid_ph then capital_balance else 0 end) as covid_bal,
       sum(case when arr_num > mar_arr_num then 1 else 0 end) as det_vol,
       sum(case when arr_num > mar_arr_num then capital_balance else 0 end) as det_bal,
       sum(case when arrears_status = mar_arr_stat then 1 else 0 end) as hold_vol,
       sum(case when arrears_status = mar_arr_stat then capital_balance else 0 end) as hold_bal,
       sum(case when arr_num < mar_arr_num then 1 else 0 end) as imp_vol,
       sum(case when arr_num < mar_arr_num then capital_balance else 0 end) as imp_bal,
       sum(case when had_covid_ph and arr_num > mar_arr_num then 1 else 0 end) as det_cv_vol,
       sum(case when had_covid_ph and arr_num > mar_arr_num then capital_balance else 0 end) as det_cv_bal,
       sum(case when had_covid_ph and arrears_status = mar_arr_stat then 1 else 0 end) as hold_cv_vol,
       sum(case when had_covid_ph and arrears_status = mar_arr_stat then capital_balance else 0 end) as hold_cv_bal,
       sum(case when had_covid_ph and arr_num < mar_arr_num then 1 else 0 end) as imp_cv_vol,
       sum(case when had_covid_ph and arr_num < mar_arr_num then capital_balance else 0 end) as imp_cv_bal,
       covid_bal/portfolio_bal as cv_exp,
       det_bal/portfolio_bal as per_det,
       hold_bal/portfolio_bal as per_held,
       imp_bal/portfolio_bal as per_imp,
       det_cv_bal/covid_bal as per_cv_det,
       hold_cv_bal/covid_bal as per_cv_held,
       imp_cv_bal/covid_bal as per_cv_imp
FROM age_buckets
GROUP BY 1);
SELECT avg(cv_exp) avg_cv_exp,
       avg(per_det) avg_per_det,
       avg(per_held) avg_per_held,
       avg(per_imp) avg_per_imp,
       avg(per_cv_det) per_cv_det,
       avg(per_cv_held) per_cv_held,
       avg(per_cv_imp) per_cv_imp
FROM grouped_age;



-- Self Employed vs Employed --
SELECT employment_status,
       count(distinct agreement_code) as cust,
       sum(capital_balance) as portfolio_bal,
       sum(case when had_covid_ph then 1 else 0 end) as covid,
       sum(case when had_covid_ph then capital_balance else 0 end) as covid_bal,
       sum(case when arr_num > mar_arr_num then 1 else 0 end) as det_vol,
       sum(case when arr_num > mar_arr_num then capital_balance else 0 end) as det_bal,
       sum(case when arrears_status = mar_arr_stat then 1 else 0 end) as hold_vol,
       sum(case when arrears_status = mar_arr_stat then capital_balance else 0 end) as hold_bal,
       sum(case when arr_num < mar_arr_num then 1 else 0 end) as imp_vol,
       sum(case when arr_num < mar_arr_num then capital_balance else 0 end) as imp_bal,
       sum(case when had_covid_ph and arr_num > mar_arr_num then 1 else 0 end) as det_cv_vol,
       sum(case when had_covid_ph and arr_num > mar_arr_num then capital_balance else 0 end) as det_cv_bal,
       sum(case when had_covid_ph and arrears_status = mar_arr_stat then 1 else 0 end) as hold_cv_vol,
       sum(case when had_covid_ph and arrears_status = mar_arr_stat then capital_balance else 0 end) as hold_cv_bal,
       sum(case when had_covid_ph and arr_num < mar_arr_num then 1 else 0 end) as imp_cv_vol,
       sum(case when had_covid_ph and arr_num < mar_arr_num then capital_balance else 0 end) as imp_cv_bal,
       covid_bal/portfolio_bal as cv_exp,
       det_bal/portfolio_bal as per_det,
       hold_bal/portfolio_bal as per_held,
       imp_bal/portfolio_bal as per_imp,
       det_cv_bal/covid_bal as per_cv_det,
       hold_cv_bal/covid_bal as per_cv_held,
       imp_cv_bal/covid_bal as per_cv_imp
FROM portfolio
WHERE employment_status IN ('SELF EMPLOYED', 'EMPLOYED')
GROUP BY 1;

SELECT employment_status,
       arr_num,
       sum(capital_balance) as total,
       sum(case when had_covid_ph then capital_balance else 0 end) as cv_bal,
       sum(case when not had_covid_ph then capital_balance else 0 end) as non_cv_bal
FROM portfolio
WHERE employment_status IN ('SELF EMPLOYED', 'EMPLOYED')
GROUP BY 1,2;


-- Settlements and Defaults --
drop table if exists mar_por;
Create temp table mar_por as (
    SELECT lt.agreement_code,
           capital_balance,
           la.main_borrower_account_id,
           (case when cd.region is null then 'Unknown' else cd.region end) as region,
           cd.employment_status,
           cd.had_covid_ph,
           (2020 - cast(birth_year as int)) as age_yr,
           case
               when age_yr BETWEEN 16 AND 24 then '16-24'
               when age_yr BETWEEN 25 AND 34 then '25-34'
               when age_yr BETWEEN 35 AND 49 then '35-49'
               when age_yr >= 50 then '50+'
               else 'Unknown'
           end as age_group
    FROM oodledata_loans.loan_timeline as lt
    LEFT JOIN oodledata_loans.loan_agreements as la
    on la.agreement_code = lt.agreement_code
    left join oodledata.customer_dim as cd
    on cd.account_id = la.main_borrower_account_id
    WHERE lt.date = '2020-03-08'
    AND is_live = 1
);
SELECT COUNT(*),
       COUNT(DISTINCT agreement_code),
       SUM(capital_balance)
from mar_por;


DROP TABLE IF EXISTS set_def;
CREATE TEMP TABLE set_def as (
    with sd as (
        SELECT sd.agreement_code,
               main_borrower_account_id,
               amount,
               type
        FROM oodledata_loans.settlements_and_defaults as sd
                 left join oodledata_loans.loan_agreements as la
                           on la.agreement_code = sd.agreement_code
        where processed_date > '2020-03-30'
    )
    SELECT sd.*,
           cd.employment_status,
           cd.had_covid_ph,
           (case when cd.region is null then 'Unknown' else cd.region end) as region,
           2020 - cast(cd.birth_year as int) as age_yr,
           case
               when age_yr BETWEEN 16 AND 24 then '16-24'
               when age_yr BETWEEN 25 AND 34 then '25-34'
               when age_yr BETWEEN 35 AND 49 then '35-49'
               when age_yr >= 50 then '50+'
               else 'Unknown'
               end                           as age_group
    FROM sd
             LEFT JOIN oodledata.customer_dim as cd
                       ON cd.account_id = sd.main_borrower_account_id
);
SELECT * FROM set_def;


-- Sets and Defs by Age --

with age_mar_por as (
    SELECT age_group,
           count(*) as vol,
           sum(capital_balance) as val,
           sum(case when had_covid_ph then capital_balance else 0 end) as cv_bal,
           sum(case when not had_covid_ph then capital_balance else 0 end) as noncv_val,
           cv_bal/val as cv_exp
    FROM mar_por
    group by 1
),
    age_sd as (
    SELECT  set_def.age_group,
            sum(case when had_covid_ph then 1 else 0 end) as cv_vol,
            sum(case when had_covid_ph then amount else 0 end) as cv_val,
            sum(case when type IN ('Default', 'VT - Default') then 1 else 0 end) as def_vol,
            sum(case when type IN ('Default', 'VT - Default') then amount else 0 end) as def_val,
            sum(case when type = 'VT' then 1 else 0 end) as vt_vol,
            sum(case when type = 'VT' then amount else 0 end) as vt_val,
            sum(case when type = 'Settlement' then 1 else 0 end) as set_vol,
            sum(case when type = 'Settlement' then amount else 0 end) as set_val,
            sum(case when type = 'Unwind' then 1 else 0 end) as unw_vol,
            sum(case when type = 'Unwind' then amount else 0 end) as unw_val,
            sum(case when not had_covid_ph and type IN ('Default', 'VT - Default') then amount else 0 end) as def_val_noncv,
            sum(case when not had_covid_ph and type  = 'VT' then amount else 0 end) as vt_val_noncv,
            sum(case when not had_covid_ph and type = 'Settlement' then amount else 0 end) as set_val_noncv,
            sum(case when not had_covid_ph and type = 'Unwind' then amount else 0 end) as unw_val_noncv,
            sum(case when had_covid_ph and type IN ('Default', 'VT - Default') then amount else 0 end) as def_val_cv,
            sum(case when had_covid_ph and type  = 'VT' then amount else 0 end) as vt_val_cv,
            sum(case when had_covid_ph and type = 'Settlement' then amount else 0 end) as set_val_cv,
            sum(case when had_covid_ph and type = 'Unwind' then amount else 0 end) as unw_val_cv
FROM set_def
GROUP BY 1)
SELECT age_sd.*,
       amp.vol,
       amp.val,
       amp.cv_bal,
       amp.cv_exp,
       def_val/val as def_per,
       vt_val/val as vt_per,
       set_val/val as set_per,
       def_val_noncv/noncv_val as noncv_def_per,
       vt_val_noncv/noncv_val as noncv_vt_per,
       set_val_noncv/noncv_val as noncv_set_per,
       def_val_cv/cv_bal as cv_def_per,
       vt_val_cv/cv_bal as cv_vt_per,
       set_val_cv/cv_bal as cv_set_per
from  age_mar_por as amp
INNER JOIN age_sd
on amp.age_group = age_sd.age_group;

-- By Region --

with regional_sd as (
    SELECT region,
           sum(case when had_covid_ph then 1 else 0 end)                             as cv_vol,
           sum(case when had_covid_ph then amount else 0 end)                        as cv_val,
           sum(case when type IN ('Default', 'VT - Default') then 1 else 0 end)      as def_vol,
           sum(case when type IN ('Default', 'VT - Default') then amount else 0 end) as def_val,
           sum(case when type = 'VT' then 1 else 0 end)                              as vt_vol,
           sum(case when type = 'VT' then amount else 0 end)                         as vt_val,
           sum(case when type = 'Settlement' then 1 else 0 end)                      as set_vol,
           sum(case when type = 'Settlement' then amount else 0 end)                 as set_val,
           sum(case when type = 'Unwind' then 1 else 0 end)                          as unw_vol,
           sum(case when type = 'Unwind' then amount else 0 end)                     as unw_val,
           sum(case when not had_covid_ph and type IN ('Default', 'VT - Default') then amount else 0 end) as def_val_noncv,
           sum(case when not had_covid_ph and type  = 'VT' then amount else 0 end) as vt_val_noncv,
           sum(case when not had_covid_ph and type = 'Settlement' then amount else 0 end) as set_val_noncv,
           sum(case when not had_covid_ph and type = 'Unwind' then amount else 0 end) as unw_val_noncv,
           sum(case when had_covid_ph and type IN ('Default', 'VT - Default') then amount else 0 end) as def_val_cv,
           sum(case when had_covid_ph and type  = 'VT' then amount else 0 end) as vt_val_cv,
           sum(case when had_covid_ph and type = 'Settlement' then amount else 0 end) as set_val_cv,
           sum(case when had_covid_ph and type = 'Unwind' then amount else 0 end) as unw_val_cv
    FROM set_def
    GROUP BY 1
),
    reg_mar_por as (
    SELECT region,
           count(*)             as vol,
           sum(capital_balance) as val,
           sum(case when had_covid_ph then capital_balance else 0 end) as cv_bal,
           sum(case when not had_covid_ph then capital_balance else 0 end) as noncv_bal,
           cv_bal/val as cv_exp
    FROM mar_por
    group by 1
)
SELECT rsd.*,
       rmp.vol,
       rmp.val,
       rmp.cv_exp,
       def_val/val as def_per,
       vt_val/val as vt_per,
       set_val/val as set_per,
       def_val_cv/cv_bal as cv_def_per,
       set_val_cv/cv_bal as cv_set_per,
       vt_val_cv/cv_bal as cv_vt_per,
       def_val_noncv/noncv_bal as noncv_def_per,
       vt_val_noncv/noncv_bal as noncv_vt_per,
       set_val_noncv/noncv_bal as noncv_set_per
FROM regional_sd as rsd
INNER JOIN reg_mar_por as rmp
on rmp.region = rsd.region;



-- By employment status --
with emp_stat_por as (
         SELECT employment_status,
                count(*)             as vol,
                sum(capital_balance) as val,
                sum(case when had_covid_ph then capital_balance else 0 end) as cv_bal,
           sum(case when not had_covid_ph then capital_balance else 0 end) as noncv_bal
         FROM mar_por
         GROUP BY 1
),
     emp_stat_sd as (
         SELECT employment_status,
                sum(case when had_covid_ph then amount else null end) as cv_cb,
                sum(case when not had_covid_ph then amount else null end) as non_cv_bal,
                sum(case when type IN ('Default', 'VT - Default') then 1 else 0 end)      as def_vol,
                sum(case when type IN ('Default', 'VT - Default') then amount else 0 end) as def_val,
                sum(case when type = 'VT' then 1 else 0 end)                              as vt_vol,
                sum(case when type = 'VT' then amount else 0 end)                         as vt_val,
                sum(case when type = 'Settlement' then 1 else 0 end)                      as set_vol,
                sum(case when type = 'Settlement' then amount else 0 end)                 as set_val,
                sum(case when type = 'Unwind' then 1 else 0 end)                          as unw_vol,
                sum(case when type = 'Unwind' then amount else 0 end)                     as unw_val,
                sum(case when not had_covid_ph and type IN ('Default', 'VT - Default') then amount else 0 end) as def_val_noncv,
                sum(case when not had_covid_ph and type  = 'VT' then amount else 0 end) as vt_val_noncv,
                sum(case when not had_covid_ph and type = 'Settlement' then amount else 0 end) as set_val_noncv,
                sum(case when not had_covid_ph and type = 'Unwind' then amount else 0 end) as unw_val_noncv,
                sum(case when had_covid_ph and type IN ('Default', 'VT - Default') then amount else 0 end) as def_val_cv,
                sum(case when had_covid_ph and type  = 'VT' then amount else 0 end) as vt_val_cv,
                sum(case when had_covid_ph and type = 'Settlement' then amount else 0 end) as set_val_cv,
                sum(case when had_covid_ph and type = 'Unwind' then amount else 0 end) as unw_val_cv
         FROM set_def
         WHERE employment_status IN ('SELF EMPLOYED', 'EMPLOYED')
         GROUP BY 1
     )
SELECT essd.*,
       esp.vol,
       esp.val,
       def_val/val as def_per,
       vt_val/val as vt_per,
       set_val/val as set_per,
       def_val_cv/cv_bal as cv_def_per,
       vt_val_cv/cv_bal as cv_vt_per,
       set_val_cv/cv_bal as cv_set_per,
       def_val_noncv/noncv_bal as noncv_def_per,
       vt_val_noncv/noncv_bal as noncv_vt_per,
       set_val_noncv/noncv_bal as noncv_set_per
FROM emp_stat_sd as essd
INNER JOIN emp_stat_por as esp
ON esp.employment_status = essd.employment_status;