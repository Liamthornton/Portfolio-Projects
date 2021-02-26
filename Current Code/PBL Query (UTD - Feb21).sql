DROP TABLE cr_scratch.lt_pbl_dates;
CREATE TABLE cr_scratch.lt_PBL_Dates  AS (
    WITH MonthRun as (SELECT 1 AS OffsetMonths FROM oodledata_loans.loan_agreements limit 1)
    SELECT TOP 1
           Last_Day(dateadd(months, -2 -OffsetMonths, current_date)) +1         AS Prev_Month_Start
         , Last_Day(dateadd(months, -1 -OffsetMonths, current_date))            AS Prev_Month_End
         , Last_Day(dateadd(months, -1 -OffsetMonths, current_date)) + 1        AS Rep_Month_Start
         , Last_Day(dateadd(months, 0 -OffsetMonths, current_date))             AS Rep_Month_End
         , CASE WHEN Rep_Month_Start+1 in ('2020-03-01') THEN Rep_Month_Start+2
                ELSE Rep_Month_Start+1 END AS HybridDateStart
         , CASE WHEN Rep_Month_End+1 in ('2020-03-01') THEN Rep_Month_End+2
            ELSE Rep_Month_End+1 END AS HybridDateEnd
    FROM MonthRun
);
select * from cr_scratch.lt_pbl_dates;

--- 1. Applications Summary - Decisioning
-- ---
DROP TABLE IF EXISTS app_summary;
CREATE TEMP TABLE app_summary as (
    with app_channel as (
        SELECT salesforce_id,
               CASE
                   WHEN (app.platform = 'POS' AND
                         introducer_category IN ('Car Supermarket', 'Franchise Dealer', 'Independent Dealer')) OR
                        (app.platform = 'POS' AND introducer_category IS NULL) THEN '3. Dealer'
                   WHEN (app.platform = 'POS' AND introducer_category IN ('Broker', 'Lead Generator'))
                       THEN '4. Non-Internet Broker'
                   WHEN (app.platform = 'POS' AND introducer_category = 'Online Broker') THEN '1. Aggregator'
                   WHEN (app.platform = 'DTC' OR introducer_category = 'DTC') OR
                        (app.platform = 'DTC' AND introducer_category IS NULL) THEN '2. DTC'
                   ELSE '5. Other' END as introducer_channel
        FROM oodledata.applications as app
                 LEFT JOIN oodledata.dealer_dim as dd
                           ON dd.dealer_id = app.introducer_id
    )
    Select TRUNC(Last_Day(created_date))                                                          AS MonthEnd
         , introducer_channel
         , Count(*)                                                                               AS AppVol
         , Sum(total_finance_amount__c)                                                           AS AppVal
         , Sum(fs.auto_accept)                                                                    AS Auto_Accept
         , Sum(case
                   when credit_search_provider = 'TU' and auto_decline = 1
                       THEN 1
                   when credit_search_provider != 'TU' and (fs.auto_accept = 0 and auto_refer = 0)
                       THEN 1
        END)                                                                                      AS Auto_Declines
         , Sum(Coalesce(auto_refer, 1))                                                           AS Auto_Refer
         , Sum(case when Coalesce(auto_refer, 1) = 1 and all_undewrite_accept = 1 THEN 1 END)     AS Manual_Acc
         , Sum(case when Coalesce(auto_refer, 1) = 1 and all_undewrite_accept = 0 THEN 1 END)     AS Manual_Dec
         , Sum(case when Coalesce(auto_refer, 1) = 1 and all_undewrite_accept is null THEN 1 END) AS Manual_Pend
         , Sum(all_undewrite_accept)                                                              AS Final_Accepts
         , Sum(CASE WHEN all_undewrite_accept = 1 THEN total_finance_amount__c END)               AS Final_Accept_Amt
         , Sum(CASE WHEN all_undewrite_accept = 0 THEN 1 ELSE 0 END)                              AS Final_Declines
         , Sum(CASE WHEN all_undewrite_accept IS NULL THEN 1 ELSE 0 END)                          AS Final_Pending
         , Sum(CASE WHEN total_finance_amount > 0 THEN 1 END)                                     AS New_Business
         , Sum(total_finance_amount)                                                              AS New_Business_Amt
    from oodledata_loan_application.funnel_summary as fs
             LEFT JOIN app_channel as app
                       on fs.loan_application_id = app.salesforce_id
             LEFT JOIN oodledata_loans.loan_agreements AS la
                       on fs.loan_application_id = la.opportunity_id
             LEFT JOIN salesforce_ownbackup_ext.opportunity_calculated AS oc
                       on fs.loan_application_id = oc.id
             LEFT JOIN salesforce_realtime.opportunity_defeed as od  --ASK JACO FOR PERMISSIONS-
                       on fs.loan_application_id = od.id
    WHERE created_date >= (SELECT Prev_Month_Start FROM cr_scratch.lt_PBL_Dates)
      AND created_date <= (SELECT Prev_Month_End FROM cr_scratch.lt_PBL_Dates)
      AND fs.test_application_flag = False
    GROUP BY 1,2
    ORDER BY 2 DESC
);
SELECT MonthEnd,
       'TOTAL',
       SUM(AppVol),
       SUM(AppVal),
       SUM(auto_accept),
       SUM(auto_declines),
       SUM(auto_refer),
       SUM(Manual_acc),
       SUM(Manual_dec),
       SUM(Manual_Pend),
       SUM(Final_Accepts),
       SUM(Final_Accept_Amt),
       SUM(Final_Declines),
       SUM(Final_Pending),
       SUM(New_Business),
       SUM(New_Business_Amt)
FROM app_summary
GROUP BY 1,2;
---------------------------
select *
FROM app_summary
ORDER BY introducer_channel ASC;



--  2. New Business - Define Residential Table ---
WITH Res_Status AS (
        select link.opportunity_id,
               residence__c_defeed.applicant__c,
               residence__c_defeed.status__c,
               residence__c_defeed.createddate
        from salesforce_realtime.residence__c_defeed
        inner join oodledata_loan_application.oodle_loan_opportunity_link as link
            on link.account_id = residence__c_defeed.applicant__c
        WHERE is_current__c = 1
        ),
     Income     AS (
        SELECT olol.opportunity_id as id,
                os.gross_annual_income as gross_annual_salary
        FROM oodledata_loan_application.oodle_loan_opportunity_link as olol
        LEFT JOIN oodlestaging_loan_application.opportunity_summary as os
            ON os.loan_application_id = olol.opportunity_id
        WHERE olol.exclusion_reason_generic IS NULL
        AND olol.loan_id IS NOT NULL
         ),
     Age        AS (
         SELECT CAST (current_age__c AS decimal(12,2)) as age,
                opportunity_id
         FROM oodledata_loan_application.oodle_loan_opportunity_link as olol
         LEFT JOIN salesforce_realtime.applicant__c_defeed as ad
            ON ad.id = olol.applicant_id
         WHERE olol.exclusion_reason_generic IS NULL
         AND olol.loan_id IS NOT NULL
        ),
     Loan_Aggs  AS (
        SELECT la.*,
               DATE_DIFF('month', la.registration_date, la.contract_date)/12.000         AS Years,
               Floor(DATE_DIFF('month', la.registration_date, la.contract_date)/12.000)  AS Years_Floor,
               CASE WHEN registration_date IS NULL OR contract_date IS NULL THEN NULL
                    WHEN DATE_DIFF('month', registration_date, contract_date) = 0  THEN -1
                    ELSE (contract_date-registration_date)/365
               END AS Car_Age
          FROM oodledata_loans.loan_agreements la
          WHERE la.contract_date>=(SELECT Rep_Month_Start FROM cr_scratch.lt_PBL_Dates) AND la.contract_date<=(SELECT Rep_Month_End FROM cr_scratch.lt_PBL_Dates)),
--- New Business Volumes ---
NB_Vols   AS (Select  TRUNC(Last_Day(la.contract_date))                                   AS MonthEnd
    ,   Count(distinct la.agreement_code)                                                                        AS NB_Total
    ,   Sum(la.current_glasses_value)                                                   AS Retail_Value
    ,   Sum(la.term)                                                                    AS Term
--- Channel ---
    ,   Sum(CASE WHEN la.platform='POS' AND dd.introducer_category in ('Car Supermarket','Franchise Dealer','Independent Dealer') THEN 1
                 WHEN la.platform='POS' AND dd.introducer_category IS NULL THEN 1 END)  AS Dealer
    ,   Sum(CASE WHEN la.platform='POS' AND dd.introducer_category in ('Broker', 'Lead Generator') THEN 1 END)
                                                                                        AS Non_Internet_Broker
    ,   Sum(CASE WHEN la.platform='POS' AND dd.introducer_category in ('Online Broker') THEN 1 END) -- Experian introducer code:'A473ADBB541344D28952BDA7739BBE61'---
                                                                                        AS Aggregator
    ,   Sum(CASE WHEN la.platform='DTC' OR  dd.introducer_category in ('DTC') THEN 1 END) AS DTC
    ,   Sum(CASE WHEN la.platform is null AND (dd.introducer_category NOT IN ('DTC') OR dd.introducer_category IS NULL)
                                                                                        THEN 1 END) AS Other_Channel
--- Customer AGE ---
    ,   ROUND(Avg(a.age), 2)                                        AS Cust_Age_Avg
    ,   Sum(CASE WHEN a.age <21 THEN 1 END)
                                                                    AS Cust_Age_LT21
    ,   Sum(CASE WHEN a.age >= 21 AND a.age<30 THEN 1 END)
                                                                    AS Cust_Age_LT30
    ,   Sum(CASE WHEN a.age >=30 AND a.age <40 THEN 1 END)
                                                                    AS Cust_Age_LT40
    ,   Sum(CASE WHEN a.age>=40 AND a.age <50 THEN 1 END)
                                                                    AS Cust_Age_LT50
    ,   Sum(CASE WHEN a.age>=50 AND a.age <60 THEN 1 END)
                                                                    AS Cust_Age_LT60
    ,   Sum(CASE WHEN a.age>=60 AND a.age <70 THEN 1 END)
                                                                    AS Cust_Age_LT70
    ,   Sum(CASE WHEN a.age >=70 THEN 1 END)
                                                                    AS Cust_Age_GT70
    ,   Sum(CASE WHEN a.age is null THEN 1 END)                     AS Cust_Age_Missing
--- Employment Status ---
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('EMPLOYED','Director') THEN 1 END)    AS Employed
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('Self-Employed','SELF EMPLOYED') THEN 1 END)
                                                                                        AS SelfEmployed
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('Retired') THEN 1 END)                AS Retired
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('Disability','Unemployed') THEN 1 END)
                                                                                        AS Homemaker
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('XXXXXXX') THEN 1 END)                AS EmployedOther
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('1') OR acc.employmentstatus__c IS NULL
                                                             THEN 1 END)                AS EmployedUnknown
--- Residential Status ---
    ,   SUM(CASE WHEN rs.status__c in ('Home Owner') THEN 1 END)                               AS Homeowner
    ,   SUM(CASE WHEN rs.status__c in ('Private Tenant','Council Tenant','Other Tenant','Lodging') THEN 1 END)                AS Tenant
    ,   SUM(CASE WHEN rs.status__c in ('Live With Parents') THEN 1 END)                               AS LivingWithParent
    ,   SUM(CASE WHEN rs.status__c in ('HM Forces') THEN 1 END)                               AS Resident_Other
    ,   SUM(CASE WHEN rs.status__c in ('Not Declared') OR rs.status__c IS NULL THEN 1 END)      AS Resident_Unknown
--- Customer Income
    ,   SUM(CASE WHEN i.gross_annual_salary IS NOT NULL AND i.gross_annual_salary>=0
                          AND i.gross_annual_salary<=150000 THEN 1 END)
                                                                                        AS GrossIncome
--- Car Age ---
    ,  Avg(CASE WHEN DATE_DIFF('month', la.registration_date, la.contract_date) !=0 THEN DATE_DIFF('month', la.registration_date, la.contract_date)::Decimal(10,2) END)
                                                                                        AS Avg_CarAge
    ,  Sum(CASE WHEN la.Car_Age=-1                      THEN 1 END)                     AS Car_AgeNew
    ,  Sum(CASE WHEN la.Car_Age= 0                      THEN 1 END)                     AS Car_AgeLT1
    ,  Sum(CASE WHEN 1<=la.Car_Age AND la.Car_Age<4     THEN 1 END)                     AS Car_AgeLT4
    ,  Sum(CASE WHEN 4<=la.Car_Age AND la.Car_Age<7     THEN 1 END)                     AS Car_AgeLT7
    ,  Sum(CASE WHEN 7<=la.Car_Age AND la.Car_Age<10    THEN 1 END)                     AS Car_AgeLT10
    ,  Sum(CASE WHEN 10<=la.Car_Age                     THEN 1 END)                     AS Car_AgeGT10
--- Vehicle Type ---
    ,  Sum(CASE WHEN od.vehicle_name__c != 'Light Commercial Vehicle' OR od.vehicle_name__c IS NULL
                                                                        THEN 1 END)     AS Car
    ,  Sum(CASE WHEN od.vehicle_name__c = 'Light Commercial Vehicle'     THEN 1 END)     AS LCV
--- Car mileage ---
    ,   Floor(100*AVG(la.mileage))/100                                                  AS AVGMileage
    ,   SUM(CASE WHEN la.mileage is not null AND la.mileage<10000 THEN 1 END)
                                                                                        AS MileageLT10k
    ,   SUM(CASE WHEN la.mileage >=10000 AND la.mileage<25000 THEN 1 END) AS MileageLT25k
    ,   SUM(CASE WHEN la.mileage >=25000 AND la.mileage<50000 THEN 1 END) AS MileageLT50k
    ,   SUM(CASE WHEN la.mileage >=50000 AND la.mileage<75000 THEN 1 END) AS MileageLT75k
    ,   SUM(CASE WHEN la.mileage >=75000 AND la.mileage<100000 THEN 1 END)
                                                                                        AS MileageLT100k
    ,   SUM(CASE WHEN la.mileage>=100000 THEN 1 END) AS MileageGT100k
    ,   SUM(CASE WHEN la.mileage is null THEN 1 END) AS MileageUnknown
--- Fuel Type ---
    ,   SUM(CASE WHEN od.fueltype__c in ('PETROL','Petrol') THEN 1 END)                  AS Petrol
    ,   SUM(CASE WHEN od.fueltype__c in ('DIESEL','Diesel') THEN 1 END)                  AS Diesel
    ,   SUM(CASE WHEN od.fueltype__c in ('Petrol/Electric','Diesel/Electric','HYB-PETROL','PETROL/ELE','HYB-DIESEL') THEN 1 END)
                                                                                        AS Hybrid
    ,   SUM(CASE WHEN od.fueltype__c in ('ELECTRIC', 'Electric (Battery)') THEN 1 END)   AS Electric
    ,   SUM(CASE WHEN od.fueltype__c in ('PETROL/GAS','GAS PETROL') THEN 1 END)          AS LPG
    ,   SUM(CASE WHEN od.fueltype__c not in ('PETROL','Petrol','DIESEL','Diesel', 'UNKNOWN',
                                           'Petrol/Electric','Diesel/Electric','HYB-PETROL','PETROL/ELE','HYB-DIESEL',
                                           'ELECTRIC', 'Electric (Battery)','PETROL/GAS','GAS PETROL') AND o.fueltype__c IS NOT NULL THEN 1 END)
                                                                                        AS FuelOther
    ,   SUM(CASE WHEN od.fueltype__c IS NULL or od.fueltype__c='UNKNOWN' THEN 1 END)      AS FuelUnknown
FROM Loan_Aggs AS la
LEFT JOIN salesforce_ownbackup_ext.opportunity_calculated oc on la.opportunity_id=oc.id
LEFT JOIN oodledata.dealer_dim dd on la.introducer_id=dd.dealer_id
LEFT JOIN salesforce_ownbackup_ext.opportunity o on la.opportunity_id=o.id
LEFT JOIN (SELECT DISTINCT id, employmentstatus__c FROM salesforce_ownbackup_ext.account where ispersonaccount=true) acc on acc.id=la.main_borrower_account_id
LEFT JOIN Res_Status rs ON rs.opportunity_id=la.opportunity_id
LEFT JOIN income i ON la.opportunity_id=i.id
LEFT JOIN age as a ON la.opportunity_id = a.opportunity_id
LEFT JOIN salesforce_realtime.opportunity_defeed od on la.opportunity_id=od.id
--LEFT JOIN (SELECT DISTINCT account_id, gross_income FROM oodledata.customer_dim) j ON la.main_borrower_account_id=j.account_id Note: Alternate source of income
WHERE la.contract_date>=(SELECT Rep_Month_Start FROM cr_scratch.lt_PBL_Dates) AND la.contract_date<=(SELECT Rep_Month_End FROM cr_scratch.lt_PBL_Dates)
GROUP BY 1
ORDER BY 1),
--- New Business Values ---
NB_Values AS (Select  TRUNC(Last_Day(la.contract_date))                                 AS MonthEnd
    ,   Sum(la.total_finance_amount)                                                    AS NB_Total
    ,   Sum(la.current_glasses_value)                                                   AS Retail_Value
    ,   Sum(la.term)                                                                    AS Term
--- Channel ---
    ,   Sum(CASE WHEN la.platform='POS' AND dd.introducer_category in ('Car Supermarket','Franchise Dealer','Independent Dealer') THEN la.total_finance_amount
                WHEN la.platform='POS' AND dd.introducer_category IS NULL THEN la.total_finance_amount END)
                                                                                        AS Dealer
    ,   Sum(CASE WHEN la.platform='POS' AND dd.introducer_category in ('Broker', 'Lead Generator') THEN la.total_finance_amount END)
                                                                                        AS Non_Internet_Broker
    ,   Sum(CASE WHEN la.platform='POS' AND dd.introducer_category in ('Online Broker') THEN la.total_finance_amount END) -- Experian introducer code:'A473ADBB541344D28952BDA7739BBE61'---
                                                                                        AS Aggregator
    ,   Sum(CASE WHEN la.platform='DTC' OR  dd.introducer_category in ('DTC')           THEN la.total_finance_amount END) AS DTC
    ,   Sum(CASE WHEN la.platform is null AND (dd.introducer_category NOT IN ('DTC') OR dd.introducer_category IS NULL)
                                                                                        THEN la.total_finance_amount END) AS Other_Channel
--- Customer AGE ---
    ,   ROUND(Avg(a.age), 2)  AS Cust_Age_Avg
    ,   Sum(CASE WHEN a.age <21 THEN la.total_finance_amount END)
                                                                    AS Cust_Age_LT21
    ,   Sum(CASE WHEN a.age >= 21 AND a.age<30 THEN la.total_finance_amount END)
                                                                    AS Cust_Age_LT30
    ,   Sum(CASE WHEN a.age >=30 AND a.age <40 THEN la.total_finance_amount END)
                                                                    AS Cust_Age_LT40
    ,   Sum(CASE WHEN a.age>=40 AND a.age <50 THEN la.total_finance_amount END)
                                                                    AS Cust_Age_LT50
    ,   Sum(CASE WHEN a.age>=50 AND a.age <60 THEN la.total_finance_amount END)
                                                                    AS Cust_Age_LT60
    ,   Sum(CASE WHEN a.age>=60 AND a.age <70 THEN la.total_finance_amount END)
                                                                    AS Cust_Age_LT70
    ,   Sum(CASE WHEN a.age >=70 THEN la.total_finance_amount END)
                                                                    AS Cust_Age_GT70
    ,   Sum(CASE WHEN a.age is null THEN la.total_finance_amount END)                     AS Cust_Age_Missing
--- Employment Status ---
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('EMPLOYED','Director') THEN la.total_finance_amount END)    AS Employed
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('Self-Employed','SELF EMPLOYED') THEN la.total_finance_amount END)
                                                                                        AS SelfEmployed
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('Retired') THEN la.total_finance_amount END)                AS Retired
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('Disability','Unemployed') THEN la.total_finance_amount END)
                                                                                        AS Homemaker
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('XXXXXXX') THEN la.total_finance_amount END)                AS EmployedOther
    ,   SUM(CASE WHEN acc.employmentstatus__c in ('1') OR acc.employmentstatus__c IS NULL THEN la.total_finance_amount
                                                                                          END)                AS EmployedUnknown
--- Residential Status ---
    ,   SUM(CASE WHEN rs.status__c in ('Home Owner') THEN la.total_finance_amount END)                               AS Homeowner
    ,   SUM(CASE WHEN rs.status__c in ('Private Tenant','Council Tenant','Other Tenant','Lodging') THEN la.total_finance_amount END)                AS Tenant
    ,   SUM(CASE WHEN rs.status__c in ('Live With Parents') THEN la.total_finance_amount END)                               AS LivingWithParent
    ,   SUM(CASE WHEN rs.status__c in ('HM Forces') THEN la.total_finance_amount END)                               AS Resident_Other
    ,   SUM(CASE WHEN rs.status__c in ('Not Declared') OR rs.status__c IS NULL THEN la.total_finance_amount END)      AS Resident_Unknown
--- Customer Income
    ,   SUM(CASE WHEN i.gross_annual_salary IS NOT NULL AND i.gross_annual_salary>=0
                        AND i.gross_annual_salary<=150000 THEN i.gross_annual_salary END)       AS GrossIncome
--- Car Age ---
    ,  Avg(DATE_DIFF('month', la.registration_date, la.contract_date)::Decimal(10,2))                         AS Avg_CarAge
    ,  Sum(CASE WHEN la.Car_Age=-1                      THEN la.total_finance_amount END)                     AS Car_AgeNew
    ,  Sum(CASE WHEN la.Car_Age= 0                      THEN la.total_finance_amount END)                     AS Car_AgeLT1
    ,  Sum(CASE WHEN 1<=la.Car_Age AND la.Car_Age<4     THEN la.total_finance_amount END)                     AS Car_AgeLT4
    ,  Sum(CASE WHEN 4<=la.Car_Age AND la.Car_Age<7     THEN la.total_finance_amount END)                     AS Car_AgeLT7
    ,  Sum(CASE WHEN 7<=la.Car_Age AND la.Car_Age<10    THEN la.total_finance_amount END)                     AS Car_AgeLT10
    ,  Sum(CASE WHEN 10<=la.Car_Age                     THEN la.total_finance_amount END)                     AS Car_AgeGT10
--- Vehicle Type ---
    ,  Sum(CASE WHEN od.vehicle_name__c != 'Light Commercial Vehicle' OR od.vehicle_name__c IS NULL THEN la.total_finance_amount END)
                                                                                                              AS Car
    ,  Sum(CASE WHEN od.vehicle_name__c = 'Light Commercial Vehicle' THEN la.total_finance_amount END)         AS LCV
--- Car mileage ---
    ,   Floor(100*AVG(la.mileage))/100                                                  AS AVGMileage
    ,   SUM(CASE WHEN la.mileage is not null AND la.mileage<10000 THEN la.total_finance_amount END)
                                                                                        AS MileageLT10k
    ,   SUM(CASE WHEN la.mileage >=10000 AND la.mileage<25000 THEN la.total_finance_amount END) AS MileageLT25k
    ,   SUM(CASE WHEN la.mileage >=25000 AND la.mileage<50000 THEN la.total_finance_amount END) AS MileageLT50k
    ,   SUM(CASE WHEN la.mileage >=50000 AND la.mileage<75000 THEN la.total_finance_amount END) AS MileageLT75k
    ,   SUM(CASE WHEN la.mileage >=75000 AND la.mileage<100000 THEN la.total_finance_amount END)
                                                                                        AS MileageLT100k
    ,   SUM(CASE WHEN la.mileage>=100000 THEN la.total_finance_amount END) AS MileageGT100k
    ,   SUM(CASE WHEN la.mileage is null THEN la.total_finance_amount END) AS MileageUnknown
--- Fuel Type ---
    ,   SUM(CASE WHEN od.fueltype__c in ('PETROL','Petrol') THEN la.total_finance_amount END)                  AS Petrol
    ,   SUM(CASE WHEN od.fueltype__c in ('DIESEL','Diesel') THEN la.total_finance_amount END)                  AS Diesel
    ,   SUM(CASE WHEN od.fueltype__c in ('Petrol/Electric','Diesel/Electric','HYB-PETROL','PETROL/ELE','HYB-DIESEL') THEN la.total_finance_amount END)
                                                                                        AS Hybrid
    ,   SUM(CASE WHEN od.fueltype__c in ('ELECTRIC', 'Electric (Battery)') THEN la.total_finance_amount END)   AS Electric
    ,   SUM(CASE WHEN od.fueltype__c in ('PETROL/GAS','GAS PETROL') THEN la.total_finance_amount END)          AS LPG
    ,   SUM(CASE WHEN od.fueltype__c not in ('PETROL','Petrol','DIESEL','Diesel', 'UNKNOWN',
                                           'Petrol/Electric','Diesel/Electric','HYB-PETROL','PETROL/ELE','HYB-DIESEL',
                                           'ELECTRIC', 'Electric (Battery)','PETROL/GAS','GAS PETROL') AND o.fueltype__c IS NOT NULL THEN la.total_finance_amount END)
                                                                                        AS FuelOther
    ,   SUM(CASE WHEN od.fueltype__c IS NULL or od.fueltype__c='UNKNOWN' THEN la.total_finance_amount END)      AS FuelUnknown
FROM Loan_Aggs AS la
LEFT JOIN salesforce_ownbackup_ext.opportunity_calculated oc on la.opportunity_id=oc.id
LEFT JOIN oodledata.dealer_dim dd on la.introducer_id=dd.dealer_id
LEFT JOIN salesforce_ownbackup_ext.opportunity o on la.opportunity_id=o.id
LEFT JOIN (SELECT DISTINCT id, employmentstatus__c FROM salesforce_ownbackup_ext.account where ispersonaccount=true) acc on acc.id=la.main_borrower_account_id
LEFT JOIN Res_Status rs ON rs.opportunity_id=la.opportunity_id
LEFT JOIN income i ON la.opportunity_id=i.id
LEFT JOIN age as a ON la.opportunity_id = a.opportunity_id
LEFT JOIN salesforce_realtime.opportunity_defeed od on la.opportunity_id=od.id
WHERE la.contract_date>=(SELECT Rep_Month_Start FROM cr_scratch.lt_PBL_Dates) AND la.contract_date<=(SELECT Rep_Month_End FROM cr_scratch.lt_PBL_Dates)
GROUP BY 1
ORDER BY 1)
--- Combine NewBusiness outputs ---
Select * from NB_Vols UNION ALL Select * From NB_Values;


-- New business by LTV breakdown --
with ltvs as (
    SELECT last_day(contract_date) as rep_month,
           agreement_code,
           total_finance_amount,
           (case when (total_finance_amount is null OR car_retail_value is null) then null
                 else (total_finance_amount / car_retail_value) end) as ltv
    FROM oodledata_loans.loan_agreements as la
    WHERE la.contract_date >= (SELECT Rep_Month_Start FROM cr_scratch.lt_PBL_Dates) AND
          la.contract_date <= (SELECT Rep_Month_End FROM cr_scratch.lt_PBL_Dates)
),
    ltv_buckets as (
    SELECT ltvs.*,
           case when ltv is null then '7. Unknown'
                when ltv < 0.7 then '1. 0.7'
                when ltv >= 0.7 and ltv < 0.8 then '2. 0.7-0.79'
                when ltv >= 0.8 and ltv < 0.9 then '3. 0.8-0.89'
                when ltv >= 0.9 and ltv < 1 then '4. 0.9-0.99'
                when ltv >= 1 and ltv < 1.09 then '5. 1-1.09'
                when ltv >= 1.1 then '6. 1.1'
           end as ltv_bucket
    FROM ltvs
    )
SELECT rep_month,
       ltv_bucket,
       COUNT(distinct agreement_code) as vol,
       SUM(total_finance_amount) as val
FROM ltv_buckets
GROUP BY 1,2
ORDER BY 2 ASC;

-- New Business by Fuel Type Breakdown--

with fuel_type_alt as (
    SELECT od.id                                                            as opportunity_id,
           od.oodle_loan__c,
           CASE WHEN od.fueltype__c IN ('PETROL','Petrol')                                                              THEN '4. Petrol'
                WHEN od.fueltype__c IN ('DIESEL', 'Diesel')                                                             THEN '1. Diesel'
                WHEN od.fueltype__c IN ('ELECTRIC', 'Electric (Battery)')                                               THEN '2. Electric'
                WHEN od.fueltype__c IN ('Petrol/Electric','Diesel/Electric','HYB-PETROL','PETROL/ELE','HYB-DIESEL')     THEN '3. Hybrid'
                WHEN od.fueltype__c IN ('PETROL/GAS','GAS PETROL')                                                      THEN '6. LPG'
                WHEN od.fueltype__c not in ('PETROL','Petrol','DIESEL','Diesel', 'UNKNOWN', 'Petrol/Electric',
                                            'Diesel/Electric','HYB-PETROL','PETROL/ELE','HYB-DIESEL',
                                           'ELECTRIC', 'Electric (Battery)','PETROL/GAS','GAS PETROL')
                                    AND od.fueltype__c IS NOT NULL                                                      THEN '5. Other'
                ELSE 'Unknown'
           END                                                              AS fuel_type
    FROM salesforce_realtime.opportunity_defeed as od
)
SELECT last_day(contract_date) as monthend,
       fuel_type,
       count(*),
       Round(avg(term),2)                                                                                   as avg_term,
       ROUND(avg(case when la.car_retail_value is not null then la.car_retail_value else null end),2)       as avg_retail_val,
       ROUND(avg(current_age__c::float),2)                                                                         as avg_age,
       ROUND(avg(CASE WHEN registration_date IS NULL OR contract_date IS NULL THEN NULL
                      ELSE abs(date_diff('months', contract_date, registration_date))::float
                 END), 2)                                                                                   AS Car_Age,
       ROUND(avg(od.mileage__c),2)                                                                          as avg_mileage
FROM oodledata_loans.loan_agreements as la
LEFT JOIN salesforce_ownbackup_ext.opportunity as o
    on o.id = la.opportunity_id
LEFT JOIN oodledata_loan_application.oodle_loan_opportunity_link as olol
    on olol.opportunity_id = la.opportunity_id
LEFT JOIN salesforce_realtime.applicant__c_defeed as acd
    on acd.id = olol.applicant_id
LEFT JOIN salesforce_realtime.opportunity_defeed as od
    on od.id = la.opportunity_id
LEFT JOIN fuel_type_alt as fta
    on fta.opportunity_id = la.opportunity_id
WHERE la.contract_date>=(SELECT Rep_Month_Start FROM cr_scratch.lt_PBL_Dates)
  AND la.contract_date<=(SELECT Rep_Month_End FROM cr_scratch.lt_PBL_Dates)
GROUP BY 1,2
ORDER BY 2 ASC;




--  3. Portfolio Volumes
Drop table cr_scratch.lt_VehicleSale;
Drop table cr_scratch.lt_Termination;
Drop table cr_scratch.lt_Repo;
Drop table cr_scratch.lt_StockPosition
--- Create a table with dates of physical repossession of vehicle ---
Create Table cr_scratch.lt_Repo AS
    (select har.agreement_code, customer__c
         , har.current_workflow_status, to_date(har.dateat, 'yyyy-mm-dd') as dt
         , Trunc(act.createddate) AS RepoDate
    from (Select createddate,customer__c, row_number() OVER (PARTITION BY customer__c ORDER BY createddate ASC) AS row_number
         FROM salesforce_ownbackup_ext.action__c where description__c ilike '%vehicle disposal record%') as act
    left join salesforce_ownbackup_ext.contact cnt on cnt.id = act.customer__c
    left join salesforce_ownbackup_ext.oodle_loan__c olc on cnt.accountid= olc.main_borrower__c
    left join riskreports_ext.hybridagreementreport har on olc.vienna_agreement_code__c=har.agreement_code and to_date(har.dateat, 'yyyy-mm-dd')=Trunc(act.createddate)
    WHERE act.row_number=1);
--- Create a table with dates of physical sale of vehicle ---
Create Table cr_scratch.lt_VehicleSale AS
    (select har.agreement_code
         , har.current_workflow_status, to_date(har.dateat, 'yyyy-mm-dd') as dt
         , Trunc(act.createddate) AS VehSaleDate
         , Act.ActualSaleDate
         , Act.GrossSaleAmt
    from (Select createddate,customer__c, row_number() OVER (PARTITION BY customer__c ORDER BY createddate ASC) AS row_number
    , CASE WHEN charindex('£',description__c)>1 THEN SUBSTRING(description__c,charindex('£',description__c)+1,charindex('.',description__c)-charindex('£',description__c)-1)*1 END AS GrossSaleAmt
    , CASE WHEN charindex('sold on ',description__c)>1 and charindex(' and ',description__c)>35 THEN TO_DATE(SUBSTRING(description__c,charindex('sold on ',description__c)+8,10),'YYYY-MM-DD') END AS ActualSaleDate
    FROM salesforce_ownbackup_ext.action__c where description__c ilike '%vehicle have been sold%') as act
    left join salesforce_ownbackup_ext.contact cnt on cnt.id = act.customer__c
    left join salesforce_ownbackup_ext.oodle_loan__c olc on cnt.accountid= olc.main_borrower__c
    left join riskreports_ext.hybridagreementreport har on olc.vienna_agreement_code__c=har.agreement_code and to_date(har.dateat, 'yyyy-mm-dd')=Trunc(act.createddate)
    WHERE act.row_number=1);
--- Create a table with dates of when the account was "terminated" ---
Create Table cr_scratch.lt_Termination AS
    (select har.agreement_code
         , har.current_workflow_status, to_date(har.dateat, 'yyyy-mm-dd') as dt
         , Trunc(act.createddate) AS TerminationDate
    from (Select createddate,customer__c, row_number() OVER (PARTITION BY customer__c ORDER BY createddate ASC) AS row_number
         FROM salesforce_ownbackup_ext.action__c where name ilike '%Loan terminated%') as act
    left join salesforce_ownbackup_ext.contact cnt on cnt.id = act.customer__c
    left join salesforce_ownbackup_ext.oodle_loan__c olc on cnt.accountid= olc.main_borrower__c
    left join riskreports_ext.hybridagreementreport har on olc.vienna_agreement_code__c=har.agreement_code and to_date(har.dateat, 'yyyy-mm-dd')=Trunc(act.createddate)
    WHERE act.row_number=1);
CREATE TABLE cr_scratch.lt_StockPosition AS (
With SDTimeline AS
    (Select sd.agreement_code, sd.type, sd.processed_date, sd.amount, sd.date AS CDR_Date, sd.sf_date, sd.vienna_date, t.TerminationDate, r.RepoDate, vs.VehSaleDate, vs.ActualSaleDate,vs.GrossSaleAmt
    from oodledata_loans.settlements_and_defaults AS sd
    left join cr_scratch.lt_Termination as t   ON t.agreement_code = sd.agreement_code
    Left Join cr_scratch.lt_Repo as r          ON r.agreement_code = sd.agreement_code
    left join cr_scratch.lt_VehicleSale as vs  ON vs.agreement_code = sd.agreement_code
    order by cdr_date),
ClosuresAtTerm AS
    (SELECT la.agreement_code, la.contract_date, la.contract_end_date, lt.cash_transactions_cumulative, la.total_finance_amount, la.total_payable
                FROM oodledata_loans.loan_agreements la
                LEFT JOIN oodledata_loans.settlements_and_defaults sd ON la.agreement_code=sd.agreement_code
                LEFT JOIN oodledata_loans.loan_timeline lt ON la.agreement_code=lt.agreement_code AND lt.date=current_date-1
                WHERE sd.date IS NULL AND lt.status_code='AG_CLOSED'),
VehicleWO AS
    (SELECT  agreement_code, to_date(dateat,'YYYY-MM-DD') AS InsuranceDate  FROM
                    (Select dateat, agreement_code, current_workflow_status, lag(current_workflow_status) over(partition by agreement_code order by dateat) AS Oldwfs
                    FROM riskreports_ext.hybridagreementreport) a
                WHERE dateat>='2019-01-01' and current_workflow_status='AG_INSURANCE SHORTFALL' and Oldwfs !='AG_INSURANCE SHORTFALL'
                    AND dateat not in ('2020-03-01')),
StatusHist AS
    (SELECT last_day(to_date(dateat,'YYYY-MM-DD')-10) as RepMon
                    , to_date(timestamptz 'epoch' + contract_date / 1000 * interval '1 second','yyyy-mm-dd') AS Contract_Date
                    , agreement_code, current_workflow_status, cur_arrears_value_exc, old_status, Old_Arrears
                    , capital_outstanding_exc
                    , CASE WHEN current_workflow_status='AG_LIVE_PRIMARY' THEN
                        CASE WHEN cur_arrears_value_exc>0 AND cur_arrears_value_exc / payment >=6 THEN 6
                             WHEN cur_arrears_value_exc>0 AND cur_arrears_value_exc / payment >=5 THEN 5
                             WHEN cur_arrears_value_exc>0 AND cur_arrears_value_exc / payment >=4 THEN 4
                             WHEN cur_arrears_value_exc>0 AND cur_arrears_value_exc / payment >=3 THEN 3
                             WHEN cur_arrears_value_exc>0 AND cur_arrears_value_exc / payment >=2 THEN 2
                             WHEN cur_arrears_value_exc>0 AND cur_arrears_value_exc / payment >=1 THEN 1
                             WHEN cur_arrears_value_exc>0 AND cur_arrears_value_exc / payment >0  THEN 0.1
                             ELSE 0 END
                        ELSE -1                            END AS Curr_Arrears
                    , CASE WHEN Old_Status='AG_LIVE_PRIMARY' THEN
                        CASE WHEN Old_Arrears>0 AND Old_Arrears / payment >=6 THEN 6
                             WHEN Old_Arrears>0 AND Old_Arrears / payment >=5 THEN 5
                             WHEN Old_Arrears>0 AND Old_Arrears / payment >=4 THEN 4
                             WHEN Old_Arrears>0 AND Old_Arrears / payment >=3 THEN 3
                             WHEN Old_Arrears>0 AND Old_Arrears / payment >=2 THEN 2
                             WHEN Old_Arrears>0 AND Old_Arrears / payment >=1 THEN 1
                             WHEN Old_Arrears>0 AND Old_Arrears / payment >0  THEN 0.1
                             ELSE 0 END
                        ELSE -1                            END AS Prev_Arrears
                FROM (SELECT dateat, agreement_code, current_workflow_status, cur_arrears_value_exc, payment, contract_date, capital_outstanding_exc
                           , lag(current_workflow_status)   over(partition by agreement_code order by dateat) AS Old_Status
                           , lag(cur_arrears_value_exc)     over(partition by agreement_code order by dateat) AS Old_Arrears
                           , row_number() OVER (PARTITION BY agreement_code ORDER BY dateat DESC) AS row_number
                FROM riskreports_ext.hybridagreementreport
                WHERE to_date(dateat,'YYYY-MM-DD') in ((Select hybriddatestart FROM cr_scratch.lt_PBL_Dates), (Select hybriddateend FROM cr_scratch.lt_PBL_Dates))) a
                WHERE row_number=1),
ViennaChanges AS
    (SELECT agreement_code
        --- Default Values ---
        ,  Sum(CASE WHEN current_workflow_status in ('AG_REPO_CRYSTALISED','AG_VT_CRYSTALISED') and Oldwfs not in ('AG_REPO_CRYSTALISED','AG_VT_CRYSTALISED') THEN 1 END) AS DupsCheck
        ,  SUM(CASE WHEN current_workflow_status in ('AG_REPO_CRYSTALISED','AG_VT_CRYSTALISED') and Oldwfs not in ('AG_REPO_CRYSTALISED','AG_VT_CRYSTALISED') THEN
                                datediff(day,To_Date('2000-01-01','YYYY-MM-DD'),to_date(dateat,'YYYY-MM-DD')) END) AS CrystalisedDate
        , SUM(CASE WHEN current_workflow_status in ('AG_REPO_CRYSTALISED','AG_VT_CRYSTALISED') and Oldwfs not in ('AG_REPO_CRYSTALISED','AG_VT_CRYSTALISED')
                                THEN OldBal END) AS CrystalisedFrom
        , SUM(CASE WHEN current_workflow_status in ('AG_REPO_CRYSTALISED','AG_VT_CRYSTALISED') and Oldwfs not in ('AG_REPO_CRYSTALISED','AG_VT_CRYSTALISED') THEN
                                cur_arrears_value_exc END) AS CrystalisedTo
        --- Backup Default Values
        ,  SUM(CASE WHEN current_workflow_status in ('AG_REPO_SHORTFALL') and Oldwfs in ('AG_REPO') THEN
                                datediff(day,To_Date('2000-01-01','YYYY-MM-DD'),to_date(dateat,'YYYY-MM-DD')) END) AS CrystalisedDate2
        , SUM(CASE WHEN current_workflow_status in ('AG_REPO_SHORTFALL') and Oldwfs in ('AG_REPO')
                                THEN OldBal END) AS CrystalisedFrom2
        , SUM(CASE WHEN current_workflow_status in ('AG_REPO_SHORTFALL') and Oldwfs in ('AG_REPO') THEN
                                cur_arrears_value_exc END) AS CrystalisedTo2
        , SUM(CASE WHEN current_workflow_status in ('AG_WRITTEN_OFF') and Oldwfs not in ('AG_WRITTEN_OFF')
                                THEN OldBal END) AS CrystalisedFrom3
        --- Net Sale Proceeds ---
        , SUM(CASE WHEN current_workflow_status in ('AG_REPO_SHORTFALL','AG_VT_CRYSTALISED') AND FirstInState=1 THEN cur_arrears_value_exc END) AS ShortfallBalance
        , SUM(CASE WHEN current_workflow_status in ('AG_REPO_SHORTFALL','AG_VT_CRYSTALISED') AND FirstInState=1 THEN 1 END) AS DupsCheck2
    FROM (Select dateat, agreement_code, current_workflow_status, cur_arrears_value_exc, capital_outstanding_exc
                          , lag(current_workflow_status) over(partition by agreement_code order by dateat)                  AS Oldwfs
                          , lag(cur_arrears_value_exc) over(partition by agreement_code order by dateat)                    AS OldArrs
                          , lag(capital_outstanding_exc) over(partition by agreement_code order by dateat)                  AS OldBal
                          , row_number() over(partition by agreement_code, current_workflow_status order by dateat)         AS FirstInState
                          , row_number() over(partition by agreement_code, current_workflow_status order by dateat desc)    AS LastInState
                    FROM riskreports_ext.hybridagreementreport
                    WHERE dateat not in ('2020-03-01')
                    ) a
        WHERE Oldwfs is not null
        GROUP BY 1)
--- Combine them into one... ---
SELECT har.*, sd.type, sd.processed_date, sd.amount as SettlementAmt, sd.terminationdate,sd.repodate,sd.vehsaledate, sd.ActualSaleDate,sd.GrossSaleAmt, sd.CDR_Date, cat.contract_end_date,vwo.InsuranceDate
, CASE WHEN sd.type in ('Settlement','Unwind') AND sd.processed_date<=RepMon                     THEN -10   -- Early Closure
       WHEN last_day(cat.contract_end_date)<= RepMon                                             THEN -9    -- Full Term closure
       WHEN sd.type in ('VT') AND last_day(sd.processed_date)<=RepMon                            THEN -8    -- VT no liability
       WHEN last_day(vwo.InsuranceDate)<= RepMon and vwo.InsuranceDate is not null               THEN 97    -- Insurance w/o
       WHEN sd.type in ('VT - Default') AND last_day(sd.processed_date)<=RepMon                  THEN 98    -- VT Default
       WHEN sd.type in ('Default') AND last_day(sd.terminationdate)<=RepMon                      THEN 99    -- Forced repossesion
       ELSE curr_Arrears END AS EndStatus
, coalesce(vc.CrystalisedFrom,vc.CrystalisedFrom2,vc.CrystalisedFrom3) AS CrystalisedFrom
, coalesce(vc.CrystalisedTo,vc.CrystalisedTo2) AS CrystalisedTo
, vc.ShortfallBalance
, coalesce(vc.CrystalisedTo,vc.CrystalisedTo2)-vc.ShortfallBalance AS NetSaleAmt
FROM StatusHist har
LEFT JOIN SDTimeline sd ON sd.agreement_code=har.agreement_code
LEFT JOIN ClosuresAtTerm cat ON cat.agreement_code=har.agreement_code
LEFT JOIN VehicleWO vwo ON vwo.agreement_code=har.agreement_code
LEFT JOIN ViennaChanges vc ON har.agreement_code=vc.agreement_code);
--- Calculate Volumes ---
SELECT sp.RepMon
        , SUM(CASE WHEN sp.current_workflow_status in ('AG_LIVE_PRIMARY') THEN 1
                   WHEN (sp.type in ('Default','VT - Default','VT') AND
                        (sp.VehSaleDate IS NULL OR sp.VehSaleDate>RepMon)) THEN 1 END)                      AS TotalPortfolio
       , SUM(CASE WHEN (sp.type in ('Default') AND last_day(sp.terminationdate)=RepMon)
                    OR (sp.type in ('VT - Default','VT','Settlement','Unwind') AND last_day(sp.processed_date)=RepMon)
                    OR last_day(sp.contract_end_date)= RepMon
                    OR last_day(sp.InsuranceDate)= RepMon THEN 1 END)                                      AS Total_Closed
,   SUM (CASE WHEN sp.type in ('VT') AND last_day(sp.processed_date)=RepMon THEN 1 END)                     AS VTNoLiability
,   SUM (CASE WHEN sp.type in ('VT - Default') AND last_day(sp.processed_date)=RepMon THEN 1 END)           AS VTVS
,   SUM (CASE WHEN sp.type in ('Settlement','Unwind') AND last_day(sp.processed_date)=RepMon THEN 1 END)    AS Settlement
,   SUM (CASE WHEN last_day(sp.contract_end_date)= RepMon THEN 1 END)                                      AS EndOfTerm
,   SUM (CASE WHEN last_day(sp.InsuranceDate) = RepMon THEN 0 WHEN sp.type in ('Default') AND last_day(sp.terminationdate)=RepMon  THEN 1 END)
                                                                                                            AS Repo
,   SUM (CASE WHEN last_day(sp.InsuranceDate)= RepMon THEN 1 END)                                           AS WriteOff
,   SUM (CASE WHEN sp.Curr_Arrears>= 2 then 1
              WHEN sp.type in ('Default') AND sp.terminationdate<=RepMon AND sp.VehSaleDate>RepMon THEN 1
              WHEN sp.type in ('VT - Default') AND last_day(sp.processed_date)<=RepMon AND sp.VehSaleDate>RepMon THEN 1 END)           AS MIA2m
,   SUM (CASE WHEN sp.Curr_Arrears>= 3 then 1
              WHEN sp.type in ('Default') AND sp.terminationdate<=RepMon AND sp.VehSaleDate>RepMon THEN 1
              WHEN sp.type in ('VT - Default') AND last_day(sp.processed_date)<=RepMon AND sp.VehSaleDate>RepMon THEN 1 END)           AS MIA3m
-- Rolls...UTD
,   SUM (CASE WHEN prev_arrears=0 THEN 1 END)                   AS UTDVol
,   SUM (CASE WHEN prev_arrears=0 AND (endstatus<-8 OR endstatus=-1) THEN 1 END)   AS UTDClosedGood
,   SUM (CASE WHEN prev_arrears=0 AND endstatus=0 THEN 1 END)   AS UTDToUTD
,   SUM (CASE WHEN prev_arrears=0 AND endstatus=0.1 THEN 1 END) AS UTDTo0Plus
,   SUM (CASE WHEN prev_arrears=0 AND endstatus=1 THEN 1 END)   AS UTDTo1
,   SUM (CASE WHEN prev_arrears=0 AND endstatus=2 THEN 1 END)   AS UTDTo2
,   SUM (CASE WHEN prev_arrears=0 AND endstatus=3 THEN 1 END)   AS UTDTo3
,   SUM (CASE WHEN prev_arrears=0 AND endstatus in (4,5,6) THEN 1 END)   AS UTDTo4
,   SUM (CASE WHEN prev_arrears=0 AND endstatus>10 THEN 1 END)  AS UTDToBad
,   SUM (CASE WHEN prev_arrears=0 AND endstatus=-8 THEN 1 END)  AS UTDToVT
-- Rolls...0.1
,   SUM (CASE WHEN prev_arrears=0.1 THEN 1 END)                   AS OneplusVol
,   SUM (CASE WHEN prev_arrears=0.1 AND (endstatus<-8 OR endstatus=-1) THEN 1 END)   AS OneplusClosedGood
,   SUM (CASE WHEN prev_arrears=0.1 AND endstatus=0 THEN 1 END)   AS OneplusToUTD
,   SUM (CASE WHEN prev_arrears=0.1 AND endstatus=0.1 THEN 1 END) AS OneplusTo0Plus
,   SUM (CASE WHEN prev_arrears=0.1 AND endstatus=1 THEN 1 END)   AS OneplusTo1
,   SUM (CASE WHEN prev_arrears=0.1 AND endstatus=2 THEN 1 END)   AS OneplusTo2
,   SUM (CASE WHEN prev_arrears=0.1 AND endstatus=3 THEN 1 END)   AS OneplusTo3
,   SUM (CASE WHEN prev_arrears=0.1 AND endstatus in (4,5,6) THEN 1 END)   AS OneplusTo4
,   SUM (CASE WHEN prev_arrears=0.1 AND endstatus>10 THEN 1 END)  AS OneplusToBad
,   SUM (CASE WHEN prev_arrears=0.1 AND endstatus=-8 THEN 1 END)  AS OneplusToVT
-- Rolls...1
,   SUM (CASE WHEN prev_arrears=1 THEN 1 END)                   AS OneVol
,   SUM (CASE WHEN prev_arrears=1 AND (endstatus<-8 OR endstatus=-1) THEN 1 END)   AS OneClosedGood
,   SUM (CASE WHEN prev_arrears=1 AND endstatus=0 THEN 1 END)   AS OneToUTD
,   SUM (CASE WHEN prev_arrears=1 AND endstatus=0.1 THEN 1 END) AS OneTo0Plus
,   SUM (CASE WHEN prev_arrears=1 AND endstatus=1 THEN 1 END)   AS OneTo1
,   SUM (CASE WHEN prev_arrears=1 AND endstatus=2 THEN 1 END)   AS OneTo2
,   SUM (CASE WHEN prev_arrears=1 AND endstatus=3 THEN 1 END)   AS OneTo3
,   SUM (CASE WHEN prev_arrears=1 AND endstatus in (4,5,6) THEN 1 END)   AS OneTo4
,   SUM (CASE WHEN prev_arrears=1 AND endstatus>10 THEN 1 END)  AS OneToBad
,   SUM (CASE WHEN prev_arrears=1 AND endstatus=-8 THEN 1 END)  AS OneToVT
-- Rolls...2
,   SUM (CASE WHEN prev_arrears=2 THEN 1 END)                   AS TwoVol
,   SUM (CASE WHEN prev_arrears=2 AND (endstatus<-8 OR endstatus=-1) THEN 1 END)   AS TwoClosedGood
,   SUM (CASE WHEN prev_arrears=2 AND endstatus=0 THEN 1 END)   AS TwoToUTD
,   SUM (CASE WHEN prev_arrears=2 AND endstatus=0.1 THEN 1 END) AS TwoTo0Plus
,   SUM (CASE WHEN prev_arrears=2 AND endstatus=1 THEN 1 END)   AS TwoTo1
,   SUM (CASE WHEN prev_arrears=2 AND endstatus=2 THEN 1 END)   AS TwoTo2
,   SUM (CASE WHEN prev_arrears=2 AND endstatus=3 THEN 1 END)   AS TwoTo3
,   SUM (CASE WHEN prev_arrears=2 AND endstatus in (4,5,6) THEN 1 END)   AS TwoTo4
,   SUM (CASE WHEN prev_arrears=2 AND endstatus>10 THEN 1 END)  AS TwoToBad
,   SUM (CASE WHEN prev_arrears=2 AND endstatus=-8 THEN 1 END)  AS TwoToVT
-- Rolls...3
,   SUM (CASE WHEN prev_arrears=3 THEN 1 END)   AS ThreeVol
,   SUM (CASE WHEN prev_arrears=3 AND (endstatus<-8 OR endstatus=-1) THEN 1 END)   AS ThreeClosedGood
,   SUM (CASE WHEN prev_arrears=3 AND endstatus=0 THEN 1 END)   AS ThreeToUTD
,   SUM (CASE WHEN prev_arrears=3 AND endstatus=0.1 THEN 1 END) AS ThreeTo0Plus
,   SUM (CASE WHEN prev_arrears=3 AND endstatus=1 THEN 1 END)   AS ThreeTo1
,   SUM (CASE WHEN prev_arrears=3 AND endstatus=2 THEN 1 END)   AS ThreeTo2
,   SUM (CASE WHEN prev_arrears=3 AND endstatus=3 THEN 1 END)   AS ThreeTo3
,   SUM (CASE WHEN prev_arrears=3 AND endstatus in (4,5,6) THEN 1 END)   AS ThreeTo4
,   SUM (CASE WHEN prev_arrears=3 AND endstatus>10 THEN 1 END)  AS ThreeToBad
,   SUM (CASE WHEN prev_arrears=3 AND endstatus=-8 THEN 1 END)  AS ThreeToVT
-- Rolls...4
,   SUM (CASE WHEN prev_arrears=4 THEN 1 END)   AS FourVol
,   SUM (CASE WHEN prev_arrears=4 AND (endstatus<-8 OR endstatus=-1) THEN 1 END)   AS FourClosedGood
,   SUM (CASE WHEN prev_arrears=4 AND endstatus=0 THEN 1 END)   AS FourToUTD
,   SUM (CASE WHEN prev_arrears=4 AND endstatus=0.1 THEN 1 END) AS FourTo0Plus
,   SUM (CASE WHEN prev_arrears=4 AND endstatus=1 THEN 1 END)   AS FourTo1
,   SUM (CASE WHEN prev_arrears=4 AND endstatus=2 THEN 1 END)   AS FourTo2
,   SUM (CASE WHEN prev_arrears=4 AND endstatus=3 THEN 1 END)   AS FourTo3
,   SUM (CASE WHEN prev_arrears=4 AND endstatus in (4,5,6) THEN 1 END)   AS FourTo4
,   SUM (CASE WHEN prev_arrears=4 AND endstatus>10 THEN 1 END)  AS FourToBad
,   SUM (CASE WHEN prev_arrears=4 AND endstatus=-8 THEN 1 END)  AS FourToVT
---Sales Performance ---
,   SUM(CASE WHEN last_day(repodate)=repmon THEN 1 ELSE 0 END) AS VehiclesRecovered
,   SUM(CASE WHEN last_day(vehsaledate)=repmon THEN 1 ELSE 0 END) AS VehiclesSold
,   Sum(CASE WHEN last_day(vehsaledate)=repmon AND COALESCE(grosssaleamt,sp.netsaleamt)<Coalesce(sp.settlementamt,sp.crystalisedfrom,1) Then 1 END) AS VehicleLoss
--- Loans in Arrears - Volumes ----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 THEN 1 END)     AS Vol3m
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 THEN 1 END)     AS Vol6m
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=12 THEN 1 END)     AS Vol12m
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=18 THEN 1 END)     AS Vol18m
--- Loans in Arrears - Early Arrears ----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 AND endstatus in (1,2) THEN 1 END) AS Vol3mlt3
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 AND endstatus in (1,2) THEN 1 END) AS Vol6mlt3
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=12 AND endstatus in (1,2) THEN 1 END) AS Vol12mlt3
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=18 AND endstatus in (1,2) THEN 1 END) AS Vol18mlt3
--- Loans in Arrears - Middle Arrears ----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 AND endstatus in (3,4,5) THEN 1 END) AS Vol3mlt6
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 AND endstatus in (3,4,5) THEN 1 END) AS Vol6mlt6
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=12 AND endstatus in (3,4,5) THEN 1 END) AS Vol12mlt6
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=18 AND endstatus in (3,4,5) THEN 1 END) AS Vol18mlt6
--- Loans in Arrears - Late Arrears ----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 AND endstatus =6 THEN 1 END) AS Vol3mGt6
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 AND endstatus =6 THEN 1 END) AS Vol6mGt6
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=12 AND endstatus =6 THEN 1 END) AS Vol12mGt6
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=18 AND endstatus =6 THEN 1 END) AS Vol18mGt6
--- Loans written off ----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 AND endstatus >=6 THEN 1 END) AS Vol3wo
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 AND endstatus >=6 THEN 1 END) AS Vol6wo
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=12 AND endstatus >=6 THEN 1 END) AS Vol12wo
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=18 AND endstatus >=6 THEN 1 END) AS Vol18wo
--- Loans written off - only made one or less payment----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 AND endstatus >=6 AND lt.instalments_satisfied<=1 THEN 1 END) AS Vol3woLT1Payment
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 AND endstatus >=6 AND lt.instalments_satisfied<=1 THEN 1 END) AS Vol6woLT1Payment
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=12 AND endstatus >=6 AND lt.instalments_satisfied<=1 THEN 1 END) AS Vol12woLT1Payment
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=18 AND endstatus >=6 AND lt.instalments_satisfied<=1 THEN 1 END) AS Vol18woLT1Payment
--- Loans written off - made two or more payments----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 AND endstatus >=6 AND lt.instalments_satisfied>1 THEN 1 END) AS Vol3woLT1Payment
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 AND endstatus >=6 AND lt.instalments_satisfied>1 THEN 1 END) AS Vol6woLT1Payment
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=12 AND endstatus >=6 AND lt.instalments_satisfied>1 THEN 1 END) AS Vol12woLT1Payment
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=18 AND endstatus >=6 AND lt.instalments_satisfied>1 THEN 1 END) AS Vol18woLT1Payment
--- Fraud - TBC ----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 AND 1=2 THEN 1 END) AS Vol3Fraud
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 AND 1=2 THEN 1 END) AS Vol6Fraud
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=12 AND 1=2 THEN 1 END) AS Vol12Fraud
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=18 AND 1=2 THEN 1 END) AS Vol18Fraud
--- Fraud - Value TBC ----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 AND 1=2 THEN 1 END) AS Vol3Fraud
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 AND 1=2 THEN 1 END) AS Vol6Fraud
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=12 AND 1=2 THEN 1 END) AS Vol12Fraud
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=18 AND 1=2 THEN 1 END) AS Vol18Fraud
--- Volume made no payment ----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 AND lt.instalments_satisfied=0 AND endstatus >=0 THEN 1 END) AS Vol3NoPmt
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 AND lt.instalments_satisfied=0 AND endstatus >=0 THEN 1 END) AS Vol6NoPmt
--- Volume made single payment ----
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=3 AND lt.instalments_satisfied=1 AND endstatus >=0 THEN 1 END) AS Vol3OnePmt
,   SUM(CASE WHEN date_diff('Month', sp.contract_date, sp.repmon)=6 AND lt.instalments_satisfied=1 AND endstatus >=0 THEN 1 END) AS Vol6OnePmt
FROM cr_scratch.lt_StockPosition sp
Left join oodledata_loans.loan_timeline lt on sp.agreement_code=lt.agreement_code AND sp.repmon=lt.date
where repmon=(SELECT Rep_Month_End FROM cr_scratch.lt_PBL_Dates)
GROUP BY 1;



-- 4. Portfolio Values
SELECT sp.RepMon
        , SUM(CASE WHEN sp.current_workflow_status in ('AG_LIVE_PRIMARY') THEN capital_outstanding_exc
                   WHEN (sp.type in ('Default','VT - Default','VT') AND
                        (sp.VehSaleDate IS NULL OR sp.VehSaleDate>RepMon)) THEN sp.cur_arrears_value_exc END)                      AS TotalPortfolio
        , SUM(CASE when (sp.current_workflow_status in ('AG_LIVE_PRIMARY')
                            OR (sp.type in ('Default','VT - Default','VT') AND (sp.VehSaleDate IS NULL OR sp.VehSaleDate>RepMon)))
                            AND repmon<la.contract_end_date THEN date_diff('Month', sp.repmon, la.contract_end_date) END)              AS TotalTerm
       , SUM(CASE WHEN (sp.type in ('Default') AND last_day(sp.terminationdate)=RepMon)
                    OR (sp.type in ('VT - Default','VT','Settlement','Unwind') AND last_day(sp.processed_date)=RepMon)
                    OR last_day(sp.contract_end_date)= RepMon
                    OR last_day(sp.InsuranceDate)= RepMon THEN coalesce(sp.crystalisedfrom, sp.settlementamt) END)                                       AS Total_Closed
,   SUM (CASE WHEN sp.type in ('VT') AND last_day(sp.processed_date)=RepMon THEN coalesce(sp.crystalisedfrom, sp.settlementamt) END)                     AS VTNoLiability
,   SUM (CASE WHEN sp.type in ('VT - Default') AND last_day(sp.processed_date)=RepMon THEN coalesce(sp.crystalisedfrom, sp.settlementamt) END)           AS VTVS
---Sales Performance ---
,   SUM(CASE WHEN last_day(repodate)=repmon THEN Coalesce(sp.settlementamt,sp.crystalisedfrom,1) ELSE 0 END)      AS VehiclesRecovered
,   SUM(CASE WHEN last_day(repodate)=repmon THEN 0 ELSE 0 END)                  AS VehiclesRecoveredCapVal

,   SUM(CASE WHEN last_day(vehsaledate)=repmon THEN Coalesce(sp.settlementamt,sp.crystalisedfrom,1) ELSE 0 END)   AS VehiclesSoldBal
,   SUM(CASE WHEN last_day(vehsaledate)=repmon THEN 0 ELSE 0 END)               AS VehiclesSoldCapVal
,   SUM(CASE WHEN last_day(vehsaledate)=repmon THEN GrossSaleAmt ELSE 0 END)    AS VehiclesSoldPrice

,   Sum(CASE WHEN last_day(vehsaledate)=repmon AND COALESCE(grosssaleamt,sp.netsaleamt)<Coalesce(sp.settlementamt,sp.crystalisedfrom,1) Then Coalesce(sp.settlementamt,sp.crystalisedfrom,1) END)  AS VehicleLossBal
,   Sum(CASE WHEN last_day(vehsaledate)=repmon AND COALESCE(grosssaleamt,sp.netsaleamt)<sp.Crystalisedfrom+1 Then 0 END)              AS VehicleLossCapVal
,   Sum(CASE WHEN last_day(vehsaledate)=repmon AND COALESCE(grosssaleamt,sp.netsaleamt)<Coalesce(sp.settlementamt,sp.crystalisedfrom,1) Then grosssaleamt END)   AS VehicleLossSoldPrice
FROM cr_scratch.lt_StockPosition sp
left join oodledata_loans.loan_agreements la on sp.agreement_code=la.agreement_code
where repmon=(SELECT Rep_Month_End FROM cr_scratch.lt_PBL_Dates)
GROUP BY 1;



--- 5. Cohort Performance ---
SELECT sp.RepMon
        , to_char(la.contract_date, 'YYYY')||' Q'||to_char(la.contract_date, 'Q') AS Vintage
        , Count(*) AS New_Business_Volume
        , Sum(la.total_finance_amount) AS New_Business_Value
        , Sum(CASE WHEN current_workflow_status not in ('AG_PENDING_CLOSURE', 'AG_CLOSED', 'AG_WRITTEN_OFF') AND capital_outstanding_exc + sp.cur_arrears_value_exc>0 THEN 1 END) AS Still_Open
        , Sum(CASE WHEN current_workflow_status not in ('AG_PENDING_CLOSURE', 'AG_CLOSED', 'AG_WRITTEN_OFF') AND capital_outstanding_exc + sp.cur_arrears_value_exc>0
                                THEN capital_outstanding_exc + sp.cur_arrears_value_exc END) AS Still_Open_Balance
        , SUM(CASE WHEN endstatus >=2 THEN 1 END) AS Vol2Plus
        , SUM(CASE WHEN endstatus >=3 THEN 1 END) AS Vol3Plus
        , SUM (CASE WHEN sp.type in ('VT - Default') AND sp.processed_date<=RepMon AND sp.repodate<=RepMon THEN 1 END)  AS VolHandbackLiabiliy
        , SUM (CASE WHEN sp.type in ('VT') AND sp.processed_date<=RepMon AND sp.repodate<=RepMon THEN 1 END)            AS VolHandbackNoLiabiliy

        , SUM(CASE WHEN sp.InsuranceDate<= RepMon THEN 0 WHEN sp.type in ('Default') AND sp.terminationdate<=RepMon THEN 1 END) AS Terminations
        , SUM(CASE WHEN 1=2 THEN 1 END) AS ReturnOfGoodsRequests
        , SUM(CASE WHEN 1=2 THEN 1 END) AS AccsReturnOfGoodsRequests
        , SUM(CASE WHEN repodate<=repmon AND sp.type in ('Default') THEN 1 END) AS ForcedPossession
        , AVG(CASE WHEN repodate<=repmon AND sp.type in ('Default') THEN
                CASE WHEN DATE_DIFF('month', la.registration_date, repodate) !=0 THEN DATE_DIFF('month', la.registration_date, repodate)::Decimal(10,2) END
            END) AS ForcedPossessionAge
        , AVG(CASE WHEN repodate<=repmon AND sp.type in ('Default') THEN
                CASE WHEN la.mileage is not null THEN la.mileage::Decimal(10,2) END
            END) AS ForcedPossessionMileage
        , SUM(CASE WHEN 1=2 THEN 1 END) AS PossessionAfterROG
        , SUM(CASE WHEN 1=2 THEN 1 END) AS PossessionNoROG
FROM cr_scratch.lt_StockPosition sp
left join oodledata_loans.loan_agreements la on sp.agreement_code=la.agreement_code
where repmon=(SELECT Rep_Month_End FROM cr_scratch.lt_PBL_Dates) and la.contract_date<=(SELECT Rep_Month_End FROM cr_scratch.lt_PBL_Dates)
GROUP BY 1,2
order by 1,2;


--- 6. COVID FBs -----

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
        WHERE type IN ('VT - Default', 'Default', 'VT', 'Settlement') AND
              sd.date <= (select Rep_Month_End from cr_scratch.lt_PBL_Dates)
        GROUP BY 1, 2
    )
    SELECT cases.agreement_code,
           type,
           sd_date,
           capital_balance as sd_balance,
           (case when type is not null then 1 else 0 end) as is_defaulted
    FROM cases
    LEFT JOIN oodledata_loans.loan_timeline as lt
        ON lt.agreement_code = cases.agreement_code and lt.date = date_add('months',-1, last_day(cases.sd_date))
    WHERE sd_date <= (select Rep_Month_End from cr_scratch.lt_PBL_Dates)
);
SELECT *
FROM sets_defs;


DROP TABLE IF EXISTS arr_and_bal;
CREATE TEMP TABLE arr_and_bal as (
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
    cur_arr as (
    SELECT f.agreement_code,
            (CASE
                   WHEN payment_reduction_adjusted_arrears_status = 'Up-to-Date' then -1
                   WHEN payment_reduction_adjusted_arrears_status = '0-Down' then 0
                   WHEN payment_reduction_adjusted_arrears_status = '1-Down' then 1
                   WHEN payment_reduction_adjusted_arrears_status = '2-Down' then 2
                   WHEN payment_reduction_adjusted_arrears_status = '3-Down' then 3
                   WHEN payment_reduction_adjusted_arrears_status = '4-Down' then 4
                   WHEN payment_reduction_adjusted_arrears_status = '5+ Down' then 5
                   ELSE null
            END) as arr_now,
           capital_balance as bal_now
    FROM forbearances as f
    LEFT JOIN oodledata_loans.loan_timeline as lt
        ON lt.agreement_code = f.agreement_code and lt.date = (select Rep_Month_End from cr_scratch.lt_PBL_Dates)
)
-- TABLE DEFINITION --
SELECT f.*,
       type,
       sd_date,
       sd_balance,
       (case when is_defaulted = 1 then 1 else 0 end) as has_defaulted,
       pre_arr,
       arr_now,
       bal_now
FROM forbearances as f
LEFT JOIN pre_ph_arr as bph
    ON bph.agreement_code = f.agreement_code
LEFT JOIN cur_arr as ca
    ON ca.agreement_code = f.agreement_code
LEFT JOIN sets_defs as sd
    on f.agreement_code = sd.agreement_code);
SELECT *
FROM arr_and_bal;


-- MONTHLY REPORT --
SELECT COUNT(*)                                                                                                                                                         as vol_ph,
       SUM(greatest(bal_now, sd_balance))                                                                                                                               as val_ph,
       SUM(case when has_defaulted = 0 and  first_fb_end_date > (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)
                THEN 1
                ELSE 0
           END)                                                                                                                                                         as vol_first_ph,
       SUM(case when has_defaulted = 0 AND
                     first_fb_end_date > (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)
                THEN bal_now
                ELSE 0
           END)                                                                                                                                                         as val_first_ph,
       SUM(case when first_fb_end_date <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)
                         AND
                     ((add_ph_start_date notnull) or (rmp_start_date != first_fb_start_date AND rmp_start_date notnull))
                         AND
                     ((add_ph_start_date <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)) or (rmp_start_date <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)))
                         AND
                     ((add_ph_end_date > (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)) or (rmp_end_date > (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)))
                         AND
                     has_defaulted = 0
                THEN 1
                ELSE 0
           END)                                                                                                                                                         as vol_ext_ph,
       SUM(case when first_fb_end_date <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)
                         AND
                     ((add_ph_start_date is not null) or (rmp_start_date != first_fb_start_date AND rmp_start_date notnull))
                         AND
                     ((add_ph_start_date <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)) or (rmp_start_date <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)))
                         AND
                     ((add_ph_end_date > (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates))  or (rmp_end_date > (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates)))
                         AND
                     has_defaulted = 0
                THEN bal_now
                ELSE 0
           END)                                                                                                                                                         as val_ext_ph,
       SUM(case when (greatest(first_fb_end_date, add_ph_end_date, rmp_end_date) <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates) ) AND
                     has_defaulted = 0 AND
                     pre_arr >= arr_now
                THEN 1
                ELSE 0
           END)                                                                                                                                                         AS vol_perf,
       SUM(case when(greatest(first_fb_end_date, add_ph_end_date, rmp_end_date) <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates) ) AND
                     has_defaulted = 0  AND
                     pre_arr >= arr_now
                THEN bal_now
                ELSE 0
           END)                                                                                                                                                         AS val_perf,
       SUM(case when (greatest(first_fb_end_date, add_ph_end_date, rmp_end_date) <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates) ) AND
                     has_defaulted = 0 AND
                     pre_arr < arr_now
                THEN 1
                ELSE 0
           END)                                                                                                                                                         AS vol_notperf,
       SUM(case when (greatest(first_fb_end_date, add_ph_end_date, rmp_end_date) <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates) ) AND
                     has_defaulted = 0 AND
                     pre_arr < arr_now
                THEN bal_now
                ELSE 0
           END)                                                                                                                                                         AS val_notperf,
       SUM(case when has_defaulted = 1 AND
                     type IN ('Default', 'VT - Default', 'VT')
                THEN 1
                ELSE 0
           END)                                                                                                                                                         AS  vol_def,
       SUM(case when has_defaulted = 1 AND
                     type IN ('Default', 'VT - Default', 'VT')
                THEN sd_balance
                ELSE 0
           END)                                                                                                                                                         AS  val_def,
       SUM(case when has_defaulted = 1 AND
                     type = 'Settlement'
                THEN 1
                ELSE 0
           END)                                                                                                                                                         AS vol_set,
       SUM(case when has_defaulted = 1 AND
                     type = 'Settlement'
                THEN sd_balance
                ELSE 0
           END)                                                                                                                                                         AS val_set
FROM arr_and_bal
WHERE first_fb_start_date <= (SELECT Rep_month_end from cr_scratch.lt_PBL_Dates);
