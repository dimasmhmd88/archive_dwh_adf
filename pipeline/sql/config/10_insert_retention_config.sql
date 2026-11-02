/* =====================================================================================
   DWH Data Retention and Archiving - initial configuration (ret.RetentionConfig, ret.RetentionParentKey)
   -------------------------------------------------------------------------------------
   Script        : 10_insert_retention_config.sql
   Version       : 0.1 (DRAFT - not reviewed, not executed against any database)
   Date          : 1 November 2026
   Source        : List Table DWH.xlsx (GitHub dimasmhmd88/archive_dwh_adf, main), sheet Sheet1,
                   421 tables (total row excluded). Requires DWH_Retention_DB_Objects_v0.5.sql.
   SizeCategory  : from column "Used Space (MB)" (requested thresholds):
                     SMALL  <= 500 MB
                     MEDIUM >  500 MB and <= 5 GB (5,120 MB; 1 GB = 1,024 MB)
                     LARGE  >  5 GB
                   No table lies between 5,000 and 5,120 MB, so 1 GB = 1,000 MB gives the same result.
   Scope         : only tables with a value in column H "retention Column":
                     own-dated tables (column name)            : 70
                     child tables (join query to header table) : 30  -> ParentTableConfigId + ret.RetentionParentKey (FR-023)
                     inserted in total                          : 100  (SMALL 61, MEDIUM 15, LARGE 24)
                     active / inactive                          : 95 / 5
                   Not inserted: 319 tables without retention column, 2 child tables whose join
                   query is invalid (listed at the end of this script).

   DEFAULTS APPLIED (NOT IN THE SOURCE LIST - CONFIRM BEFORE USE)
   - DwhRetentionYears = 3, BlobRetentionYears = 5 (BRD defaults, BR-03); child = header (DBR-20).
   - InitialCutoffMethod = BATCH_DELETE for every table. TABLE_REBUILD (MD-04) must be decided per
     table (candidates: LARGE tables) - change the value before the Initial Cut-off Run.
   - BlobPath = lower(<schema>/<table>) (MD-07).
   - IsActive = 0 for tables with an open point (see comment on the row); 1 otherwise.
     The Initial Cut-off master pipeline in automatic mode (CR-01) selects every ACTIVE table.
   NOT VERIFIED HERE (checked at run time by usp_BeginTable): table and column exist (V-01/V-02),
   column is a date type (V-03), no NULLs (V-04), join key unique in header (V-11).

   KNOWN LIMITATION F-12 / OQ-26 - LARGE child table with SMALL or MEDIUM header table:
   such a child is never selected by the Initial Cut-off automatic mode (DBR-05 vs DBR-18). Affected:
     bos.BOS_SD_DjrTracking (24,518.72 MB) -> header bos.BOS_SD_FDjr (846.13 MB, MEDIUM)
     bos.BOS_SD_FDjrItem (22,202.87 MB) -> header bos.BOS_SD_FDjr (846.13 MB, MEDIUM)
     bos.BOS_SD_FInvoiceItem (13,774.72 MB) -> header bos.BOS_SD_FInvoice (3,561.81 MB, MEDIUM)
     bos.JTI_SD_FdjrItemStatus (18,680.42 MB) -> header bos.BOS_SD_FDjr (846.13 MB, MEDIUM)
     bos.JTI_SD_FdjrItemStatus_new (7,086.69 MB) -> header bos.BOS_SD_FDjr (846.13 MB, MEDIUM)
   Re-runnable: rows that already exist (same schema + table) are not inserted again and not changed.
   ===================================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'ret.RetentionConfig', N'U') IS NULL OR OBJECT_ID(N'ret.RetentionParentKey', N'U') IS NULL
BEGIN
    ;THROW 50901, N'Schema ret objects not found. Deploy DWH_Retention_DB_Objects_v0.5.sql first.', 1;
END;

BEGIN TRANSACTION;

DECLARE @Cfg TABLE (SchemaName SYSNAME NOT NULL, TableName SYSNAME NOT NULL, RetentionColumn SYSNAME NULL,
                    ParentSchema SYSNAME NULL, ParentTable SYSNAME NULL, SizeCategory VARCHAR(10) NOT NULL,
                    IsActive BIT NOT NULL, UsedSpaceMB DECIMAL(18, 2) NOT NULL, SourceRow INT NOT NULL);
DECLARE @Key TABLE (SchemaName SYSNAME NOT NULL, TableName SYSNAME NOT NULL, KeyOrdinal TINYINT NOT NULL,
                    ChildColumn SYSNAME NOT NULL, ParentColumn SYSNAME NOT NULL);

-- 1. Own-dated tables (header tables and stand-alone tables)
INSERT INTO @Cfg (SchemaName, TableName, RetentionColumn, ParentSchema, ParentTable, SizeCategory, IsActive, UsedSpaceMB, SourceRow)
VALUES
    (N'BI', N'Fact_B2B', N'Date', NULL, NULL, 'MEDIUM', 1, 858.29, 62),
    (N'BI', N'Fact_BOS_ARTrans', N'Date', NULL, NULL, 'LARGE', 1, 9983.45, 63),
    (N'BI', N'Fact_BrandFunnel', N'Date', NULL, NULL, 'SMALL', 1, 273.13, 64),
    (N'BI', N'Fact_BrandFunnel_BK', N'Date', NULL, NULL, 'SMALL', 1, 200.92, 65),
    (N'BI', N'Fact_BrandImage', N'Date', NULL, NULL, 'SMALL', 1, 123.52, 66),
    (N'BI', N'Fact_CASBankSettlementDetails', N'dtmLastUpdate', NULL, NULL, 'SMALL', 1, 26.16, 67),
    (N'BI', N'Fact_CustPaymentDetails', N'PaymentDate', NULL, NULL, 'SMALL', 1, 205.45, 68),
    (N'BI', N'Fact_CustPaymentItem2', N'PaymentDate', NULL, NULL, 'SMALL', 1, 107.58, 69),
    (N'BI', N'Fact_FDO_Detail', N'Date', NULL, NULL, 'LARGE', 1, 22022.56, 70),
    (N'BI', N'Fact_FDO_Detail_DSD', N'Date', NULL, NULL, 'SMALL', 1, 300.44, 71),
    (N'BI', N'Fact_FDO_Header', N'Date', NULL, NULL, 'LARGE', 1, 19466.18, 72),
    (N'BI', N'Fact_FDO_Header_DSD', N'Date', NULL, NULL, 'SMALL', 1, 245.34, 73),
    (N'BI', N'fact_OOS', N'Date', NULL, NULL, 'SMALL', 1, 4.25, 74),
    (N'BI', N'Fact_PD_POSM_WS', N'Date', NULL, NULL, 'LARGE', 1, 14176.87, 75),
    (N'BI', N'Fact_PO_Invoice', N'Date', NULL, NULL, 'SMALL', 1, 8.55, 76),
    (N'BI', N'Fact_PO_Receipt', N'Date', NULL, NULL, 'SMALL', 1, 55.79, 77),
    (N'BI', N'Fact_PostingIntegration', N'TransactionDate', NULL, NULL, 'MEDIUM', 1, 3605.37, 78),
    (N'BI', N'Fact_RemainStock', N'Date', NULL, NULL, 'LARGE', 1, 20757.87, 79),
    (N'BI', N'Fact_Retail_Audit', N'Date', NULL, NULL, 'SMALL', 1, 6.81, 80),
    (N'BI', N'Fact_SD_Invoice', N'dtmLastUpdated', NULL, NULL, 'LARGE', 1, 9436.02, 83),
    (N'BI', N'Fact_SD_Invoice_DSD', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 116.34, 84),
    (N'BI', N'Fact_Switching_tracker', N'Date', NULL, NULL, 'SMALL', 1, 7.54, 85),
    (N'BI', N'Fact_Switching_tracker_BK', N'Date', NULL, NULL, 'SMALL', 1, 5.50, 86),
    (N'BI', N'Fact_TMTransaction', N'TransactionDate', NULL, NULL, 'MEDIUM', 1, 2195.77, 87),
    (N'bos', N'BOS_AR_ArTrans', N'dtmDate', NULL, NULL, 'LARGE', 1, 7392.09, 92),
    (N'bos', N'BOS_INV_StockHistory', N'dtmTransaction', NULL, NULL, 'LARGE', 1, 7389.49, 112),
    (N'bos', N'BOS_MD_FSurvey', N'dtmDate', NULL, NULL, 'MEDIUM', 1, 555.46, 115),
    (N'bos', N'BOS_MD_FSurveyItem', N'dtmDate', NULL, NULL, 'LARGE', 1, 90755.07, 116),
    (N'bos', N'BOS_PUR_FPo_s', N'dtmPO', NULL, NULL, 'SMALL', 1, 0.00, 127),
    (N'bos', N'BOS_PUR_FPoReceipt_s', N'dtmreceipt', NULL, NULL, 'SMALL', 1, 7.07, 130),
    (N'bos', N'BOS_SD_FDjr', N'dtmFdjr', NULL, NULL, 'MEDIUM', 1, 846.13, 136),
    (N'bos', N'BOS_SD_FDjrOOR', N'dtmFdjr', NULL, NULL, 'SMALL', 1, 198.09, 138),
    (N'bos', N'BOS_SD_FDo', N'dtmDelivery', NULL, NULL, 'LARGE', 1, 57358.63, 140),
    (N'bos', N'BOS_SD_FInvoice', N'dtmPeriode', NULL, NULL, 'MEDIUM', 1, 3561.81, 142),
    (N'bos', N'BOS_SD_FSo', N'dtmOrder', NULL, NULL, 'SMALL', 1, 19.59, 144),
    (N'bos', N'BOS_SD_FTO', N'dtmFTO', NULL, NULL, 'SMALL', 1, 0.02, 148),
    (N'bos', N'BOS_SD_FTONOO', N'dtmFTO', NULL, NULL, 'SMALL', 1, 0.00, 150),
    (N'bos', N'BOS_SD_FTOOOR', N'dtmFTO', NULL, NULL, 'SMALL', 1, 0.02, 152),
    (N'bos', N'BOS_SD_RemainStockInCust', N'dtmMobileTransaction', NULL, NULL, 'LARGE', 0, 14386.50, 155), -- Child table bos.BOS_SD_RemainStockInCustItem is not configured (invalid join query); archiving this header first would leave its child rows without header. Activate after the child is fixed.
    (N'bos', N'BOS_SD_Route', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 1.68, 157),
    (N'bos', N'BOS_SD_SalesOrganization', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 0.05, 159),
    (N'bos', N'BOS_SD_TOTracking', N'dtmNext', NULL, NULL, 'SMALL', 1, 0.07, 160),
    (N'bos', N'JTI_MD_NOOFSurvey', N'dtmDate', NULL, NULL, 'SMALL', 1, 189.66, 180),
    (N'bos', N'JTI_MD_NOOFSurveyItem', N'dtmDate', NULL, NULL, 'LARGE', 1, 7412.81, 181),
    (N'bos', N'JTI_MD_NOORegistrationMonitoring', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 246.96, 182),
    (N'bos', N'JTI_SCW_Stock', N'dtmDate', NULL, NULL, 'SMALL', 1, 72.95, 193),
    (N'bos', N'JTI_SD_BrandDistCustomerCoverage', N'dtmLastWeek', NULL, NULL, 'LARGE', 1, 5482.56, 195),
    (N'bos', N'JTI_SD_BrandDistDetail', N'dtmDate', NULL, NULL, 'LARGE', 1, 36459.85, 196),
    (N'bos', N'JTI_SD_BrandDistHeader', N'dtmLastUpdate', NULL, NULL, 'MEDIUM', 1, 3740.00, 197),
    (N'bos', N'JTI_SD_FDjrNOO', N'dtmFdjr', NULL, NULL, 'SMALL', 1, 43.67, 200),
    (N'bos', N'JTI_SD_RemainStockInCustomer', N'dtmDate', NULL, NULL, 'LARGE', 1, 24328.45, 202),
    (N'bos', N'JTI_SD_SalesInformationbyBrand', N'dtmDelivery', NULL, NULL, 'LARGE', 1, 226751.82, 203),
    (N'bos', N'JTI_SD_SalesReport', N'dtmDate', NULL, NULL, 'MEDIUM', 1, 3880.36, 205),
    (N'bos', N'JTI_SD_SalesReport_backup', N'dtmDate', NULL, NULL, 'MEDIUM', 1, 1087.61, 206),
    (N'bos', N'JTI_SD_SummaryBrandDistDetail', N'dtmLastUpdated', NULL, NULL, 'MEDIUM', 1, 2015.48, 207),
    (N'bos', N'JTI_SD_SummaryBrandDistHeader', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 16.54, 208),
    (N'bos', N'JTI_SD_SummarySalesInformationbyBrand', N'dtmLastUpdated', NULL, NULL, 'MEDIUM', 1, 3983.10, 209),
    (N'bos', N'JTI_SD_SummarySalesReportMonthly', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 56.07, 210),
    (N'bos', N'JTI_SD_SummarySalesReportWeekly', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 321.88, 211),
    (N'bos', N'JTI_SD_TargetByBrand', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 0.20, 212),
    (N'bos', N'JTI_SPV_DailySchedule', N'dtmDS', NULL, NULL, 'SMALL', 1, 15.16, 213),
    (N'bos', N'JTI_SPV_FSurvey', N'dtmDate', NULL, NULL, 'LARGE', 1, 21512.66, 216),
    (N'bos', N'JTI_SPV_FWeeklyPlanCalendar', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 2.55, 220),
    (N'bos', N'JTI_SPV_JoinCallOutletPlan', N'dtmDate', NULL, NULL, 'SMALL', 0, 392.38, 224), -- Marked '?' in column I: retention column not confirmed.
    (N'bos', N'JTI_SPV_JourneyCall', N'dtmLastUpdated', NULL, NULL, 'SMALL', 0, 137.91, 225), -- Marked '?' in column I: retention column not confirmed.
    (N'dbo', N'BOS_SD_TOTracking', N'dtmNext', NULL, NULL, 'SMALL', 0, 0.06, 270), -- Child table dbo.BOS_SD_TOTrackingProduct is not configured (invalid join query); archiving this header first would leave its child rows without header. Activate after the child is fixed.
    (N'sli', N'BOS_SD_ROUTE_DSD_H', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 73.03, 324),
    (N'sli', N'BOS_SD_ROUTE_H', N'dtmLastUpdated', NULL, NULL, 'SMALL', 1, 85.78, 325),
    (N'sli', N'Fact_Sales_Incentive', N'Date', NULL, NULL, 'SMALL', 1, 20.70, 344),
    (N'sli', N'Fact_Sales_Incentive_DSD', N'Date', NULL, NULL, 'SMALL', 1, 3.00, 345);

-- 2. Child tables (business date taken from the header table, FR-023)
INSERT INTO @Cfg (SchemaName, TableName, RetentionColumn, ParentSchema, ParentTable, SizeCategory, IsActive, UsedSpaceMB, SourceRow)
VALUES
    (N'bos', N'BOS_AR_ArTransRefDoc', NULL, N'bos', N'BOS_AR_ArTrans', 'LARGE', 1, 10827.28, 93),
    (N'bos', N'BOS_PUR_FPo_sItem', NULL, N'bos', N'BOS_PUR_FPo_s', 'SMALL', 1, 24.74, 128),
    (N'bos', N'BOS_PUR_FPo_sItemDelivery', NULL, N'bos', N'BOS_PUR_FPo_s', 'SMALL', 1, 12.08, 129),
    (N'bos', N'BOS_PUR_FPoReceipt_sItem', NULL, N'bos', N'BOS_PUR_FPoReceipt_s', 'SMALL', 1, 25.23, 131),
    (N'bos', N'BOS_SD_DjrTracking', NULL, N'bos', N'BOS_SD_FDjr', 'LARGE', 1, 24518.72, 135),
    (N'bos', N'BOS_SD_FDjrItem', NULL, N'bos', N'BOS_SD_FDjr', 'LARGE', 0, 22202.87, 137), -- Query typo 'bwhere' (alias b + WHERE) - interpreted as alias b.
    (N'bos', N'BOS_SD_FDjrOORItem', NULL, N'bos', N'BOS_SD_FDjrOOR', 'MEDIUM', 1, 735.66, 139),
    (N'bos', N'BOS_SD_FDoItem', NULL, N'bos', N'BOS_SD_FDo', 'LARGE', 1, 32378.37, 141),
    (N'bos', N'BOS_SD_FInvoiceItem', NULL, N'bos', N'BOS_SD_FInvoice', 'LARGE', 1, 13774.72, 143),
    (N'bos', N'BOS_SD_FSoItem', NULL, N'bos', N'BOS_SD_FSo', 'SMALL', 1, 46.08, 145),
    (N'bos', N'BOS_SD_FSoItemBonusSource', NULL, N'bos', N'BOS_SD_FSo', 'SMALL', 1, 0.26, 146),
    (N'bos', N'BOS_SD_FSoItemDelivery', NULL, N'bos', N'BOS_SD_FSo', 'SMALL', 1, 27.47, 147),
    (N'bos', N'BOS_SD_FTOItem', NULL, N'bos', N'BOS_SD_FTO', 'SMALL', 1, 0.05, 149),
    (N'bos', N'BOS_SD_FTONOOItem', NULL, N'bos', N'BOS_SD_FTONOO', 'SMALL', 1, 0.00, 151),
    (N'bos', N'BOS_SD_FTOOORItem', NULL, N'bos', N'BOS_SD_FTOOOR', 'SMALL', 1, 0.00, 153),
    (N'bos', N'BOS_SD_RouteItem', NULL, N'bos', N'BOS_SD_Route', 'SMALL', 1, 16.66, 158),
    (N'bos', N'BOS_SD_TOTrackingProduct', NULL, N'bos', N'BOS_SD_TOTracking', 'SMALL', 1, 1.99, 161),
    (N'bos', N'JTI_SD_FdjrItemStatus', NULL, N'bos', N'BOS_SD_FDjr', 'LARGE', 1, 18680.42, 198),
    (N'bos', N'JTI_SD_FdjrItemStatus_new', NULL, N'bos', N'BOS_SD_FDjr', 'LARGE', 1, 7086.69, 199),
    (N'bos', N'JTI_SD_FDjrNOOItem', NULL, N'bos', N'JTI_SD_FDjrNOO', 'SMALL', 1, 273.74, 201),
    (N'bos', N'JTI_SPV_DailyScheduleItem', NULL, N'bos', N'JTI_SPV_DailySchedule', 'SMALL', 1, 0.00, 214),
    (N'bos', N'JTI_SPV_DailyScheduleItemDetail', NULL, N'bos', N'JTI_SPV_DailySchedule', 'SMALL', 1, 43.33, 215),
    (N'bos', N'JTI_SPV_FSurveyItem', NULL, N'bos', N'JTI_SPV_FSurvey', 'MEDIUM', 1, 2404.93, 217),
    (N'bos', N'JTI_SPV_FSurveyItemPhoto', NULL, N'bos', N'JTI_SPV_FSurvey', 'SMALL', 1, 0.00, 218),
    (N'bos', N'JTI_SPV_FSurveyQuestion', NULL, N'bos', N'JTI_SPV_FSurvey', 'MEDIUM', 1, 2593.31, 219),
    (N'bos', N'JTI_SPV_FWeeklyPlanCalendarDay', NULL, N'bos', N'JTI_SPV_FWeeklyPlanCalendar', 'SMALL', 1, 6.49, 221),
    (N'bos', N'JTI_SPV_FWeeklyPlanCalendarItem', NULL, N'bos', N'JTI_SPV_FWeeklyPlanCalendar', 'SMALL', 1, 8.38, 222),
    (N'bos', N'JTI_SPV_FWeeklyPlanCalendarItemDetail', NULL, N'bos', N'JTI_SPV_FWeeklyPlanCalendar', 'SMALL', 1, 13.75, 223),
    (N'sli', N'BOS_SD_RouteItem_DSD_H', NULL, N'sli', N'BOS_SD_ROUTE_DSD_H', 'SMALL', 1, 40.83, 326),
    (N'sli', N'BOS_SD_RouteItem_H', NULL, N'sli', N'BOS_SD_ROUTE_H', 'MEDIUM', 1, 590.93, 327);

-- 3. Join keys of the child tables (ChildColumn = column of the child, ParentColumn = column of the header)
INSERT INTO @Key (SchemaName, TableName, KeyOrdinal, ChildColumn, ParentColumn)
VALUES
    (N'bos', N'BOS_AR_ArTransRefDoc', 1, N'szdocId', N'szdocId'),
    (N'bos', N'BOS_PUR_FPo_sItem', 1, N'szFPO_sId', N'szFPO_sId'),
    (N'bos', N'BOS_PUR_FPo_sItemDelivery', 1, N'szFPO_sId', N'szFPO_sId'),
    (N'bos', N'BOS_PUR_FPoReceipt_sItem', 1, N'szFPOReceipt_sId', N'szFPOReceipt_sId'),
    (N'bos', N'BOS_SD_DjrTracking', 1, N'szFDjrId', N'szFDjrId'),
    (N'bos', N'BOS_SD_FDjrItem', 1, N'szFDjrId', N'szFDjrId'),
    (N'bos', N'BOS_SD_FDjrOORItem', 1, N'szFDjrId', N'szFDjrId'),
    (N'bos', N'BOS_SD_FDoItem', 1, N'szdoId', N'szdoId'),
    (N'bos', N'BOS_SD_FInvoiceItem', 1, N'szFInvoiceId', N'szFInvoiceId'),
    (N'bos', N'BOS_SD_FSoItem', 1, N'szFSoId', N'szFSoId'),
    (N'bos', N'BOS_SD_FSoItemBonusSource', 1, N'szFSoId', N'szFSoId'),
    (N'bos', N'BOS_SD_FSoItemDelivery', 1, N'szFSoId', N'szFSoId'),
    (N'bos', N'BOS_SD_FTOItem', 1, N'szFTOId', N'szFTOId'),
    (N'bos', N'BOS_SD_FTONOOItem', 1, N'szFTOId', N'szFTOId'),
    (N'bos', N'BOS_SD_FTOOORItem', 1, N'szFTOId', N'szFTOId'),
    (N'bos', N'BOS_SD_RouteItem', 1, N'szRouteId', N'szRouteId'),
    (N'bos', N'BOS_SD_TOTrackingProduct', 1, N'szTOTrackingId', N'szTOTrackingId'),
    (N'bos', N'JTI_SD_FdjrItemStatus', 1, N'szFDjrId', N'szFDjrId'),
    (N'bos', N'JTI_SD_FdjrItemStatus_new', 1, N'szFDjrId', N'szFDjrId'),
    (N'bos', N'JTI_SD_FDjrNOOItem', 1, N'szFDjrId', N'szFDjrId'),
    (N'bos', N'JTI_SPV_DailyScheduleItem', 1, N'szDSId', N'szDSId'),
    (N'bos', N'JTI_SPV_DailyScheduleItemDetail', 1, N'szDSId', N'szDSId'),
    (N'bos', N'JTI_SPV_FSurveyItem', 1, N'szSurveyId', N'szSurveyId'),
    (N'bos', N'JTI_SPV_FSurveyItemPhoto', 1, N'szSurveyId', N'szSurveyId'),
    (N'bos', N'JTI_SPV_FSurveyQuestion', 1, N'szSurveyId', N'szSurveyId'),
    (N'bos', N'JTI_SPV_FWeeklyPlanCalendarDay', 1, N'szFWPCId', N'szFWPCId'),
    (N'bos', N'JTI_SPV_FWeeklyPlanCalendarItem', 1, N'szFWPCId', N'szFWPCId'),
    (N'bos', N'JTI_SPV_FWeeklyPlanCalendarItemDetail', 1, N'szFWPCId', N'szFWPCId'),
    (N'sli', N'BOS_SD_RouteItem_DSD_H', 1, N'szRouteId', N'szRouteId'),
    (N'sli', N'BOS_SD_RouteItem_H', 1, N'szRouteId', N'szRouteId');

-- 4. Header and stand-alone tables first (children need the TableConfigId of their header)
INSERT INTO ret.RetentionConfig
    (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears,
     BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
SELECT s.SchemaName, s.TableName, s.RetentionColumn, NULL, 3, 5,
       LOWER(s.SchemaName + N'/' + s.TableName), 'BATCH_DELETE', s.IsActive, s.SizeCategory
FROM @Cfg AS s
WHERE s.ParentTable IS NULL
  AND NOT EXISTS (SELECT 1 FROM ret.RetentionConfig AS c WHERE c.SchemaName = s.SchemaName AND c.TableName = s.TableName)
ORDER BY s.SourceRow;

-- 5. Child tables
INSERT INTO ret.RetentionConfig
    (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears,
     BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
SELECT s.SchemaName, s.TableName, NULL, p.TableConfigId, p.DwhRetentionYears, p.BlobRetentionYears,
       LOWER(s.SchemaName + N'/' + s.TableName), 'BATCH_DELETE', s.IsActive, s.SizeCategory
FROM @Cfg AS s
JOIN ret.RetentionConfig AS p ON p.SchemaName = s.ParentSchema AND p.TableName = s.ParentTable
WHERE s.ParentTable IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ret.RetentionConfig AS c WHERE c.SchemaName = s.SchemaName AND c.TableName = s.TableName)
ORDER BY s.SourceRow;

-- 6. Join keys (only for child tables that have no keys yet)
INSERT INTO ret.RetentionParentKey (TableConfigId, KeyOrdinal, ChildColumn, ParentColumn)
SELECT c.TableConfigId, k.KeyOrdinal, k.ChildColumn, k.ParentColumn
FROM @Key AS k
JOIN ret.RetentionConfig AS c ON c.SchemaName = k.SchemaName AND c.TableName = k.TableName
WHERE c.ParentTableConfigId IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ret.RetentionParentKey AS x WHERE x.TableConfigId = c.TableConfigId);

-- 7. Check: every listed table is configured; every child table has join keys
IF EXISTS (SELECT 1 FROM @Cfg AS s WHERE NOT EXISTS (SELECT 1 FROM ret.RetentionConfig AS c
                                                     WHERE c.SchemaName = s.SchemaName AND c.TableName = s.TableName))
   OR EXISTS (SELECT 1 FROM ret.RetentionConfig AS c JOIN @Cfg AS s ON s.SchemaName = c.SchemaName AND s.TableName = c.TableName
              WHERE c.ParentTableConfigId IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k WHERE k.TableConfigId = c.TableConfigId))
BEGIN
    ROLLBACK TRANSACTION;
    ;THROW 50902, N'Configuration incomplete (missing table or join keys); transaction rolled back.', 1;
END;

COMMIT TRANSACTION;
GO

-- 8. Result per size category
SELECT c.SizeCategory, c.IsActive,
       SUM(CASE WHEN c.ParentTableConfigId IS NULL THEN 1 ELSE 0 END) AS OwnDatedTables,
       SUM(CASE WHEN c.ParentTableConfigId IS NOT NULL THEN 1 ELSE 0 END) AS ChildTables
FROM ret.RetentionConfig AS c
GROUP BY c.SizeCategory, c.IsActive
ORDER BY CASE c.SizeCategory WHEN 'SMALL' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END, c.IsActive DESC;
GO

/* =====================================================================================
   NOT INSERTED - child tables whose join query in column H is invalid (fix the list, then add them)
   =====================================================================================
   bos.BOS_SD_RemainStockInCustItem (Excel row 156, 32,222.31 MB, LARGE): Join condition(s) not between child and header: a.szCustId = a.szCustId (typo?).
      query: select top 10 a.* from bos.BOS_SD_RemainStockInCustItem a,bos.BOS_SD_RemainStockInCust b where a.szCustId=a.szCustId and a.dtmMobileTransaction=b.dtmMobileTransaction and a.szSalesId=b.szSalesId
   dbo.BOS_SD_TOTrackingProduct (Excel row 271, 1.86 MB, SMALL): Join query does not name this table plus exactly one header table (query uses bos.BOS_SD_TOTrackingProduct, bos.BOS_SD_TOTracking).
      query: select top 10 a.* from bos.BOS_SD_TOTrackingProduct a,bos.BOS_SD_TOTracking b where a.szTOTrackingId=b.szTOTrackingId

   NOT INSERTED - 319 tables without retention column (column H empty), by schema and size:
     BI   : SMALL 63, MEDIUM 1
     bos  : SMALL 105, MEDIUM 4
     dbo  : SMALL 51
     sli  : SMALL 86, MEDIUM 6, LARGE 3
     dbo.PNL_OPE_Depreciation: Marked 'All' in column I, no retention column: meaning unclear (keep all? archive all?).
   ===================================================================================== */
