-- do we need an is_live flag? since defaulted loans show a capital balance of 0 --
DROP TABLE IF EXISTS pttma_cb;
CREATE TEMP TABLE pttma_cb as (
    with balances as (
        select la.agreement_code,
               case when lt.date = '2021-01-31' then lt.capital_balance else null end as jan_bal,
               case when lt2.date = '2020-12-31' then lt2.capital_balance else null end as dec_bal
        from oodledata_loans.loan_agreements as la
        left join oodledata_loans.loan_timeline as lt
            on lt.agreement_code = la.agreement_code
            and lt.date ='2021-01-31'
        left join oodledata_loans.loan_timeline as lt2
            on lt2.agreement_code = la.agreement_code
            and lt2.date = '2020-12-31'
        WHERE la.agreement_code IN (SELECT DISTINCT agreement_code
                                    FROM oodledata_assets_and_liabilities.provisions_through_time_management_accounts as pttma
                                    WHERE pttma.date = '2021-01-31')
        )
    SELECT pttma.*,
           jan_bal,
           dec_bal
    FROM oodledata_assets_and_liabilities.provisions_through_time_management_accounts as pttma
    LEFT JOIN balances as bal
        ON bal.agreement_code = pttma.agreement_code
    WHERE pttma.date = '2021-01-31');
SELECT *
FROM pttma_cb
limit 150;


-- LIVE SCENARIO --

-- summary --
select sum(case when scenario = 'live' then provision_held else 0 end) as live_prov_held,
       sum(case when scenario = 'live' then jan_bal else 0 end) as live_pool_cb,
       sum(case when previous_scenario = 'live' then previous_provision_held else 0 end) as prev_live_prov_held,
       sum(case when previous_scenario = 'live' then dec_bal else 0 end) as prev_live_pool_cb,
       live_prov_held - prev_live_prov_held as live_prov_charge
from pttma_cb pc;

-- New business--
with new_busi as (
    SELECT pttma.agreement_code,
           min(date) as origination_month
    FROM oodledata_assets_and_liabilities.provisions_through_time_management_accounts as pttma
    GROUP BY 1
    HAVING origination_month = '2021-01-31')
select sum(provision_held),
       sum(jan_bal)
from new_busi as nb
left join pttma_cb
on pttma_cb.agreement_code = nb.agreement_code;

-- transferred from live to terminated --
SELECT sum(-previous_provision_held),
       sum(dec_bal),
       sum(jan_bal)
FROM pttma_cb
WHERE previous_scenario = 'live' AND
      scenario = 'terminated';

-- transferred from live to covid  --
SELECT SUM(-previous_provision_held) as charge,
       SUM(dec_bal),
       SUM(jan_bal)
FROM pttma_cb
WHERE previous_scenario = 'live' AND
      scenario = 'covid';

-- Settlements and Unwinds --
SELECT latest_model_state,
       SUM(-previous_provision_held),
       SUM(dec_bal),
       SUM(jan_bal)
FROM pttma_cb
WHERE latest_model_state IN (9001, 9999) AND
      previous_model_state NOT IN (9001,9999) AND
      scenario = 'live' AND
      previous_scenario = 'live'
GROUP BY 1;

-- Intra-bucket movements - static rolls --
SELECT latest_model_state,
       SUM(provision_held - previous_provision_held) as intra_bucket_charge,
       SUM(dec_bal),
       SUM(jan_bal)
FROM pttma_cb
WHERE previous_scenario = 'live'
      and scenario = 'live'
      AND previous_model_state = latest_model_state
GROUP BY 1;

-- Inter-bucket movements - deteriorated rolls --
select sum(case when previous_model_state = 0 AND latest_model_state = 1 then (provision_held - previous_provision_held) else 0 end) as r021,
       sum(case when previous_model_state = 1 and latest_model_state = 2 then (provision_held - previous_provision_held) else 0 end) as r122,
       sum(case when previous_model_state = 2 and latest_model_state = 3 then (provision_held - previous_provision_held) else 0 end) as r223,
       sum(case when previous_model_state = 3 and latest_model_state = 4 then (provision_held - previous_provision_held) else 0 end) as r324,
       sum(case when previous_model_state = 0 AND latest_model_state = 1 then dec_bal else 0 end) as r021_dcb,
       sum(case when previous_model_state = 0 AND latest_model_state = 1 then jan_bal else 0 end) as r021_jcb,
       sum(case when previous_model_state = 1 and latest_model_state = 2 then dec_bal else 0 end) as r122_dcb,
       sum(case when previous_model_state = 1 and latest_model_state = 2 then jan_bal else 0 end) as r122_jcb,
       sum(case when previous_model_state = 2 and latest_model_state = 3 then dec_bal else 0 end) as r223_dcb,
       sum(case when previous_model_state = 2 and latest_model_state = 3 then jan_bal else 0 end) as r223_jcb,
       sum(case when previous_model_state = 3 and latest_model_state = 4 then dec_bal else 0 end) as r324_dcb,
       sum(case when previous_model_state = 3 and latest_model_state = 4 then jan_bal else 0 end) as r324_jcb
from pttma_cb
WHERE previous_scenario = 'live' AND
      scenario = 'live' AND
      latest_model_state IN (0,1,2,3,4);


-- Inter-bucket movements - improved rolls --
SELECT sum(case when previous_model_state = 1 AND latest_model_state = 0 then (provision_held - previous_provision_held) else 0 end) as r120,
       sum(case when previous_model_state = 2 and latest_model_state = 1 then (provision_held - previous_provision_held) else 0 end) as r221,
       sum(case when previous_model_state = 3 and latest_model_state = 2 then (provision_held - previous_provision_held) else 0 end) as r322,
       sum(case when previous_model_state = 4 and latest_model_state = 3 then (provision_held - previous_provision_held) else 0 end) as r423,
       sum(case when previous_model_state = 1 AND latest_model_state = 0 then dec_bal else 0 end) as r120_dcb,
       sum(case when previous_model_state = 1 AND latest_model_state = 0 then jan_bal else 0 end) as r120_jcb,
       sum(case when previous_model_state = 2 and latest_model_state = 1 then dec_bal else 0 end) as r221_dcb,
       sum(case when previous_model_state = 2 and latest_model_state = 1 then jan_bal else 0 end) as r221_jcb,
       sum(case when previous_model_state = 3 and latest_model_state = 2 then dec_bal else 0 end) as r322_dcb,
       sum(case when previous_model_state = 3 and latest_model_state = 2 then jan_bal else 0 end) as r322_jcb,
       sum(case when previous_model_state = 4 and latest_model_state = 3 then dec_bal else 0 end) as r423_dcb,
       sum(case when previous_model_state = 4 and latest_model_state = 3 then jan_bal else 0 end) as r423_jcb
FROM pttma_cb
WHERE latest_model_state IN (0,1,2,3,4) AND
      previous_scenario = 'live' AND
      scenario = 'live';


-- From covid to live -- previous provision held is what is leaving the covid bucket -- live charge gets the new provison held
SELECT SUM(provision_held),
       SUM(dec_bal),
       SUM(jan_bal)
FROM pttma_cb
where previous_scenario = 'covid' AND
      scenario = 'live';

-- Live provisions against commissions --
SELECT SUM(case when date = '2020-12-31' and scenario = 'live' then provision_held_against_commission else 0 end) as prev_comms_prov,
       SUM(case when date = '2021-01-31' and scenario = 'live' then provision_held_against_commission else 0 end) as comms_prov,
       comms_prov - prev_comms_prov as comms_prov_charge
FROM oodledata_assets_and_liabilities.provisions_through_time_management_accounts as pttma;

---- TERMINATED SCENARIO ---
--SUMMARY--
select sum(case when scenario = 'terminated' then provision_held else 0 end) as term_prov_held,
       sum(case when previous_scenario = 'terminated' then previous_provision_held else 0 end) as prev_term_prov_held,
       sum(case when previous_scenario = 'terminated' then dec_bal else 0 end) as prev_term_pool_cb,
       sum(case when scenario = 'terminated' then jan_bal else 0 end) as term_pool_cb,
       term_prov_held-prev_term_prov_held as term_prov_charge
from pttma_cb;

-- from live to terminated --
SELECT SUM(provision_held),
       SUM(dec_bal),
       SUM(jan_bal)
FROM pttma_cb
WHERE previous_scenario = 'live' AND
      scenario = 'terminated';

-- from covid to terminated --
SELECT SUM(provision_held),
       sum(dec_bal),
       sum(jan_bal)
FROM pttma_cb
WHERE previous_scenario = 'covid' AND
      scenario = 'terminated';

-- inter-termination-state movements --
SELECT previous_model_state,
       latest_model_state,
       SUM(provision_held - previous_provision_held),
       SUM(dec_bal),
       SUM(jan_bal)
FROM pttma_cb
WHERE scenario = 'terminated' AND
      previous_scenario = 'terminated' AND
      latest_model_state != previous_model_state
GROUP BY 1,2;

-- intra-termination state movements --

SELECT latest_model_state,
       SUM(provision_held - previous_provision_held) as provision_charge,
       SUM(provision_held) as provision_held
FROM oodledata_assets_and_liabilities.provisions_through_time_management_accounts as pttma
WHERE scenario = 'terminated' AND
      previous_scenario = 'terminated' AND
      date = '2021-01-31' AND
      latest_model_state = previous_model_state
group by 1;

-- Unwinds and settlements --
SELECT SUM(case when latest_model_state = '9001' then (-previous_provision_held) else 0 end) as settlement_prov_charge,
       SUM(case when latest_model_state = '9999' then (-previous_provision_held) else 0 end) as unwind_prov_charge
FROM oodledata_assets_and_liabilities.provisions_through_time_management_accounts as pttma
WHERE previous_scenario = 'terminated' AND
      date = '2021-01-31';

-- COVID SCENARIO --

-- scenario-level summary --
SELECT SUM(case when scenario = 'covid' then provision_held else 0 end) as cv_provision_held,
       SUM(case when scenario = 'covid' then jan_bal else 0 end) as cv_pool_cb,
       SUM(case when previous_scenario = 'covid' then previous_provision_held else 0 end) as prev_provision_held,
       SUM(case when previous_scenario = 'covid' then dec_bal else 0 end) as prev_cv_pool_cb,
       (cv_provision_held- prev_provision_held) AS provision_charge
FROM pttma_cb;

-- from live to covid --
SELECT SUM(provision_held) as live_2_covid_charge,
       SUM(dec_bal),
       SUM(jan_bal)
FROM pttma_cb
WHERE previous_scenario = 'live' AND
      scenario ='covid';

-- from terminated to covid? --
SELECT SUM(provision_held),
       SUM(jan_bal),
       SUM(dec_bal)
FROM pttma_cb
WHERE previous_scenario = 'terminated' AND
      scenario = 'covid';

-- from covid to live --
SELECT SUM(-previous_provision_held),
       SUM(dec_bal),
       SUM(jan_bal)
FROM pttma_cb
WHERE scenario = 'live' AND
      previous_scenario = 'covid';

-- from covid to terminated --
SELECT SUM(-previous_provision_held),
       SUM(dec_bal),
       SUM(jan_bal)
FROM pttma_cb
WHERE previous_scenario = 'covid' AND
      scenario = 'terminated';

-- Intra-bucket movements - static rolls --
SELECT latest_model_state,
       SUM(case when previous_model_state = latest_model_state then (provision_held - previous_provision_held) else 0 end) as intra_bucket_charge,
       SUM(case when previous_model_state = latest_model_state then dec_bal else 0 end) as dec_pool_bal,
       SUM(case when previous_model_state = latest_model_state then jan_bal else 0 end) as jan_pool_bal
FROM pttma_cb
WHERE previous_scenario = 'covid'
      and scenario = 'covid'
GROUP BY 1;

-- Inter-bucket movements - deteriorated rolls --
select sum(case when previous_model_state = 0 AND latest_model_state = 1 then (provision_held - previous_provision_held) else 0 end) as r021,
       sum(case when previous_model_state = 1 and latest_model_state = 2 then (provision_held - previous_provision_held) else 0 end) as r122,
       sum(case when previous_model_state = 2 and latest_model_state = 3 then (provision_held - previous_provision_held) else 0 end) as r223,
       sum(case when previous_model_state = 3 and latest_model_state = 4 then (provision_held - previous_provision_held) else 0 end) as r324,
       sum(case when previous_model_state = 0 AND latest_model_state = 1 then dec_bal else 0 end) as r021_dcb,
       sum(case when previous_model_state = 0 AND latest_model_state = 1 then jan_bal else 0 end) as r021_jcb,
       sum(case when previous_model_state = 1 and latest_model_state = 2 then dec_bal else 0 end) as r122_dcb,
       sum(case when previous_model_state = 1 and latest_model_state = 2 then jan_bal else 0 end) as r122_jcb,
       sum(case when previous_model_state = 2 and latest_model_state = 3 then dec_bal else 0 end) as r223_dcb,
       sum(case when previous_model_state = 2 and latest_model_state = 3 then jan_bal else 0 end) as r223_jcb,
       sum(case when previous_model_state = 3 and latest_model_state = 4 then dec_bal else 0 end) as r324_dcb,
       sum(case when previous_model_state = 3 and latest_model_state = 4 then jan_bal else 0 end) as r324_jcb
from pttma_cb
WHERE previous_scenario = 'covid' AND
      scenario = 'covid';

-- Inter-bucket movements - improved rolls --
SELECT sum(case when previous_model_state = 1 AND latest_model_state = 0 then (provision_held - previous_provision_held) else 0 end) as r120,
       sum(case when previous_model_state = 2 and latest_model_state = 1 then (provision_held - previous_provision_held) else 0 end) as r221,
       sum(case when previous_model_state = 3 and latest_model_state = 2 then (provision_held - previous_provision_held) else 0 end) as r322,
       sum(case when previous_model_state = 4 and latest_model_state = 3 then (provision_held - previous_provision_held) else 0 end) as r423,
       sum(case when previous_model_state = 1 AND latest_model_state = 0 then dec_bal else 0 end) as r120_dcb,
       sum(case when previous_model_state = 1 AND latest_model_state = 0 then jan_bal else 0 end) as r120_jcb,
       sum(case when previous_model_state = 2 and latest_model_state = 1 then dec_bal else 0 end) as r221_dcb,
       sum(case when previous_model_state = 2 and latest_model_state = 1 then jan_bal else 0 end) as r221_jcb,
       sum(case when previous_model_state = 3 and latest_model_state = 2 then dec_bal else 0 end) as r322_dcb,
       sum(case when previous_model_state = 3 and latest_model_state = 2 then jan_bal else 0 end) as r322_jcb,
       sum(case when previous_model_state = 4 and latest_model_state = 3 then dec_bal else 0 end) as r423_dcb,
       sum(case when previous_model_state = 4 and latest_model_state = 3 then jan_bal else 0 end) as r423_jcb
FROM pttma_cb
WHERE previous_scenario = 'covid' AND
      scenario = 'covid';

-- settled or unwound --
SELECT SUM(case when latest_model_state = '9001' then (-previous_provision_held) else 0 end) as settlement_prov_charge,
       SUM(case when latest_model_state = '9001' then dec_bal else 0 end) as prev_set_pool_cb,
       SUM(case when latest_model_state = '9001' then jan_bal else 0 end) as set_pool_cb,
       SUM(case when latest_model_state = '9999' then (-previous_provision_held) else 0 end) as unwind_prov_charge,
       SUM(case when latest_model_state = '9999' then dec_bal else 0 end) as prev_unw_pool_cb,
       SUM(case when latest_model_state = '9999' then jan_bal else 0 end) as unw_pool_cb
FROM pttma_cb
WHERE previous_scenario = 'covid';

-- Comms charge --
SELECT SUM(case when date = '2020-12-31' and scenario = 'covid' then provision_held_against_commission else 0 end) as prev_comms_prov,
       SUM(case when date = '2021-01-31' and scenario = 'covid' then provision_held_against_commission else 0 end) as comms_prov,
       comms_prov - prev_comms_prov as comms_prov_charge
FROM oodledata_assets_and_liabilities.provisions_through_time_management_accounts as pttma;

SELECT sum(provision_held - previous_provision_held)
FROM oodledata_assets_and_liabilities.provisions_through_time_management_accounts
WHERE date = '2021-01-31' AND
      previous_model_state = 10 AND
      latest_model_state = 10;


------------