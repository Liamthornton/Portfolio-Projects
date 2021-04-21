-- Provision Movement --

-- live summary
SELECT sum(case when scenario = 'live' then provision_held end) as current_prov,
       sum(case when previous_scenario = 'live' then previous_provision_held end) as last_prov,
       current_prov - last_prov as provision_charge
FROM oodledata_assets_and_liabilities.provision_timeline
WHERE date = '2021-03-31';

---- INTER BUCKET MOVEMENTS ---
-- live to covid
SELECT sum(-previous_provision_held)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' AND
      pt.previous_scenario = 'live' AND
      pt.scenario = 'covid'

-- live to terminated
SELECT sum(-previous_provision_held)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' AND
      pt.previous_scenario = 'live' AND
      pt.scenario = 'terminated'

-- covid to live
SELECT sum(provision_held)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' AND
      pt.previous_scenario = 'covid' AND
      pt.scenario = 'live'

-- terminated to live
SELECT sum(provision_held)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' AND
      pt.previous_scenario = 'terminated' AND
      pt.scenario = 'live'

---- INTRABUCKET MOVEMENTS ---
-- new business provision ---
SELECT sum(provision_held),
       count(distinct pt.agreement_code)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
LEFT JOIN oodledata_loans.loan_agreements as la
    ON la.agreement_code = pt.agreement_code
WHERE date = '2021-03-31' and
      previous_scenario is null and
      previous_state is null;


-- Static rolls --
SELECT state,
       SUM(provision_held - previous_provision_held) as static_charge
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' AND
      scenario = previous_scenario AND
      scenario = 'live' AND
      previous_state = state
GROUP BY 1;

-- Improved rolls --
-- linear movements --
SELECT previous_state,
       state,
       SUM(provision_held - previous_provision_held)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' AND
      state != previous_state AND
      state IN (0,1,2,3,4) AND
      state = previous_state - 1 AND
      previous_scenario = scenario AND
      scenario = 'live'
GROUP BY 1,2
ORDER BY 1 asc,2 asc;

-- non linear movements --
SELECT previous_state,
       state,
       SUM(provision_held - previous_provision_held)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' AND
      state != previous_state AND
      state IN (0,1,2,3,4) AND
      state != previous_state - 1 AND
      state < previous_state AND
      previous_scenario = scenario AND
      scenario = 'live'
GROUP BY 1,2
ORDER BY 1 asc,2 asc;

-- Deteriorated Rolls --
-- linear movements --
SELECT previous_state,
       state,
       SUM(provision_held - previous_provision_held) as charge
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' AND
      state != previous_state AND
      state IN (0,1,2,3,4) AND
      state > previous_state AND
      previous_scenario = scenario AND
      scenario = 'live'
GROUP BY 1,2
ORDER BY 1 asc,2 asc;

-- non linear movements --
SELECT previous_state,
       state,
       SUM(provision_held - previous_provision_held)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' AND
      state > previous_state AND
      state IN (0,1,2,3,4) AND
      state != previous_state +1 AND
      previous_scenario = scenario AND
      scenario = 'live'
GROUP BY 1,2
ORDER BY 1 asc,2 asc;

-- Settlements and Unwinds --
SELECT state,
       sum(provision_held - previous_provision_held) as charge
FROM oodledata_assets_and_liabilities.provision_timeline
WHERE date = '2021-03-31' and
      scenario = previous_scenario and scenario = 'live' and
      state IN (9999, 9001) and previous_state NOT IN (9999,9001)
GROUP BY 1;


--- Terminated scenario ---
-- Summary
SELECT sum(case when scenario = 'terminated' then provision_held end) as prov_held,
       sum(case when previous_scenario = 'terminated' then previous_provision_held end) as prev_prov_held,
       prov_held - prev_prov_held as prov_charge
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' ;

-- Inter scenario movements
SELECT previous_scenario,
       scenario,
       sum(provision_held)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' and
      scenario = 'terminated' and
      previous_scenario != scenario
GROUP BY 1,2;

-- Intra scenario movements

-- inter-termination state movements
SELECT previous_state,
       state,
       sum(provision_held-previous_provision_held)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' and
      scenario = 'terminated' and
      previous_scenario = 'terminated' and
      previous_state != state
GROUP BY 1,2
ORDER BY 1 ASC, 2 ASC;


-- Intra state movements
SELECT state,
       sum(provision_held-previous_provision_held)
FROM oodledata_assets_and_liabilities.provision_timeline as pt
WHERE date = '2021-03-31' and
      scenario = 'terminated' and
      previous_scenario = 'terminated' and
      previous_state = state
GROUP BY 1
ORDER BY 1 ASC;

------------
