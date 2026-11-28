/* =====================================================================================
   DWH Data Retention and Archiving - initial configuration, go-live phase 1
   -------------------------------------------------------------------------------------
   Script        : config/10_insert_retention_config.sql
   Version       : 0.2 (DRAFT - not reviewed, not executed against any database)
   Date          : 11 November 2026 (v0.1: 1 November 2026)
   Sources       : FSD_DWH_Data_Retention_v1.1 (10 Nov 2026, Draft for Review - NOT approved):
                   Appendix A.1 "Proposed Phase-1 Tables" (31 Class A tables), MD-05 (child tables excluded
                   from go-live phase 1), MD-07 (BlobPath <schema>.<table>, container dwh-archive), MD-08.
                   List Table DWH.xlsx (Used Space) for the size check.
   Requires      : DWH_Retention_DB_Objects_v0.6.sql (column LogRetentionYears, BlobPath rule without slash).

   CHANGES FROM v0.1 (review "pipeline-agus vs FSD v1.1", finding F-05)
   - Only the 31 phase-1 tables of FSD Appendix A.1 are configured and active (v0.1: 100 tables, 95 active).
   - BlobPath = LOWER(<schema>.<table>) (v0.1: <schema>/<table>).
   - Rows of v0.1 that are not in Appendix A.1 (child tables, their headers, Class A1 tables with a last-update
     column, backup tables) are set IsActive = 0 (FSD 4.20: later-phase tables are not inserted or inserted
     inactive). Their join keys stay in ret.RetentionParentKey for a later phase.
   - ArchiveContainer = dwh-archive when not yet set.

   SIZE CATEGORY (from Used Space, matches FSD Appendix A.1): SMALL <= 500 MB, MEDIUM > 500 MB and <= 5 GB
   (5,120 MB), LARGE > 5 GB.   SMALL 15  MEDIUM 5  LARGE 11

   DEFAULTS (not decided in the FSD - confirm before the Initial Cut-off Run)
   - DwhRetentionYears 3, BlobRetentionYears 5, LogRetentionYears 3 (MD-03, MD-08).
   - InitialCutoffMethod BATCH_DELETE for all tables. FSD A.1 marks the 11 LARGE tables as "rebuild candidate,
     downtime": change to TABLE_REBUILD per table after the decision; LARGE tables always need a downtime
     reference on the Initial Cut-off Run (FSD 4.4).

   BEHAVIOUR (re-runnable, one transaction)
   - Missing phase-1 tables are inserted.
   - Existing phase-1 rows still PENDING and without any archive file are aligned (date column, size, BlobPath,
     IsActive = 1). Rows already in progress or completed are not changed and are listed in the result.
   - Every other row of ret.RetentionConfig is set IsActive = 0.
   ===================================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'ret.RetentionConfig', N'U') IS NULL OR COL_LENGTH(N'ret.RetentionConfig', N'LogRetentionYears') IS NULL
BEGIN
    ;THROW 50911, N'Schema ret v0.6 not found (column LogRetentionYears missing). Deploy DWH_Retention_DB_Objects_v0.6.sql first.', 1;
END;

DECLARE @Phase1 TABLE (SchemaName SYSNAME NOT NULL, TableName SYSNAME NOT NULL, RetentionColumn SYSNAME NOT NULL,
                       SizeCategory VARCHAR(10) NOT NULL, UsedSpaceMB DECIMAL(18, 2) NOT NULL,
                       PRIMARY KEY (SchemaName, TableName));

-- FSD Appendix A.1 (31 tables). UsedSpaceMB from List Table DWH.xlsx, for information only.
INSERT INTO @Phase1 (SchemaName, TableName, RetentionColumn, SizeCategory, UsedSpaceMB)
VALUES
    (N'bos', N'JTI_SD_SalesInformationbyBrand', N'dtmDelivery', 'LARGE', 226751.82),
    (N'bos', N'BOS_MD_FSurveyItem', N'dtmDate', 'LARGE', 90755.07),
    (N'bos', N'JTI_SD_BrandDistDetail', N'dtmDate', 'LARGE', 36459.85),
    (N'bos', N'JTI_SD_RemainStockInCustomer', N'dtmDate', 'LARGE', 24328.45),
    (N'BI', N'Fact_FDO_Detail', N'Date', 'LARGE', 22022.56),
    (N'BI', N'Fact_RemainStock', N'Date', 'LARGE', 20757.87),
    (N'BI', N'Fact_FDO_Header', N'Date', 'LARGE', 19466.18),
    (N'BI', N'Fact_PD_POSM_WS', N'Date', 'LARGE', 14176.87),
    (N'BI', N'Fact_BOS_ARTrans', N'Date', 'LARGE', 9983.45),
    (N'bos', N'BOS_INV_StockHistory', N'dtmTransaction', 'LARGE', 7389.49),
    (N'bos', N'JTI_MD_NOOFSurveyItem', N'dtmDate', 'LARGE', 7412.81),
    (N'bos', N'JTI_SD_SalesReport', N'dtmDate', 'MEDIUM', 3880.36),
    (N'BI', N'Fact_PostingIntegration', N'TransactionDate', 'MEDIUM', 3605.37),
    (N'BI', N'Fact_TMTransaction', N'TransactionDate', 'MEDIUM', 2195.77),
    (N'BI', N'Fact_B2B', N'Date', 'MEDIUM', 858.29),
    (N'bos', N'BOS_MD_FSurvey', N'dtmDate', 'MEDIUM', 555.46),
    (N'BI', N'Fact_FDO_Detail_DSD', N'Date', 'SMALL', 300.44),
    (N'BI', N'Fact_BrandFunnel', N'Date', 'SMALL', 273.13),
    (N'BI', N'Fact_CustPaymentDetails', N'PaymentDate', 'SMALL', 205.45),
    (N'BI', N'Fact_FDO_Header_DSD', N'Date', 'SMALL', 245.34),
    (N'bos', N'JTI_MD_NOOFSurvey', N'dtmDate', 'SMALL', 189.66),
    (N'BI', N'Fact_CustPaymentItem2', N'PaymentDate', 'SMALL', 107.58),
    (N'BI', N'Fact_BrandImage', N'Date', 'SMALL', 123.52),
    (N'BI', N'Fact_PO_Receipt', N'Date', 'SMALL', 55.79),
    (N'bos', N'JTI_SCW_Stock', N'dtmDate', 'SMALL', 72.95),
    (N'sli', N'Fact_Sales_Incentive', N'Date', 'SMALL', 20.70),
    (N'BI', N'Fact_PO_Invoice', N'Date', 'SMALL', 8.55),
    (N'BI', N'Fact_Retail_Audit', N'Date', 'SMALL', 6.81),
    (N'BI', N'Fact_Switching_tracker', N'Date', 'SMALL', 7.54),
    (N'BI', N'fact_OOS', N'Date', 'SMALL', 4.25),
    (N'sli', N'Fact_Sales_Incentive_DSD', N'Date', 'SMALL', 3.00);

BEGIN TRANSACTION;

-- 1. Archive container (MD-07). Not overwritten when another value is already set.
UPDATE ret.RetentionParameter SET ArchiveContainer = N'dwh-archive', ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7()
 WHERE ParameterSetId = 1 AND ArchiveContainer IS NULL;

-- 2. Insert missing phase-1 tables
INSERT INTO ret.RetentionConfig
    (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears, LogRetentionYears,
     BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
SELECT p.SchemaName, p.TableName, p.RetentionColumn, NULL, 3, 5, 3,
       LOWER(p.SchemaName + N'.' + p.TableName), 'BATCH_DELETE', 1, p.SizeCategory
FROM @Phase1 AS p
WHERE NOT EXISTS (SELECT 1 FROM ret.RetentionConfig AS c WHERE c.SchemaName = p.SchemaName AND c.TableName = p.TableName);

-- 3. Align existing phase-1 rows that have not started archiving
UPDATE c
   SET RetentionColumn     = p.RetentionColumn,
       ParentTableConfigId = NULL,
       SizeCategory        = p.SizeCategory,
       BlobPath            = LOWER(p.SchemaName + N'.' + p.TableName),
       IsActive            = 1
  FROM ret.RetentionConfig AS c
  JOIN @Phase1 AS p ON p.SchemaName = c.SchemaName AND p.TableName = c.TableName
  JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
 WHERE s.InitialCutoffStatus = 'PENDING'
   AND NOT EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a WHERE a.TableConfigId = c.TableConfigId)
   AND NOT EXISTS (SELECT 1 FROM ret.RetentionTableLog AS l WHERE l.TableConfigId = c.TableConfigId AND l.IsValidated = 1)
   AND (   ISNULL(c.RetentionColumn, N'') <> p.RetentionColumn OR c.ParentTableConfigId IS NOT NULL
        OR c.SizeCategory <> p.SizeCategory OR c.BlobPath <> LOWER(p.SchemaName + N'.' + p.TableName) OR c.IsActive = 0);

-- 4. Everything outside phase 1 inactive (FSD 4.20, MD-05)
UPDATE c
   SET IsActive = 0
  FROM ret.RetentionConfig AS c
 WHERE c.IsActive = 1
   AND NOT EXISTS (SELECT 1 FROM @Phase1 AS p WHERE p.SchemaName = c.SchemaName AND p.TableName = c.TableName);

-- 5. Check: all 31 phase-1 tables configured
IF (SELECT COUNT(*) FROM ret.RetentionConfig AS c JOIN @Phase1 AS p ON p.SchemaName = c.SchemaName AND p.TableName = c.TableName) <> 31
BEGIN
    ROLLBACK TRANSACTION;
    ;THROW 50912, N'Not all 31 phase-1 tables are configured; transaction rolled back.', 1;
END;

COMMIT TRANSACTION;

-- 6. Result
SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn, c.SizeCategory, c.InitialCutoffMethod, c.BlobPath,
       c.IsActive, s.InitialCutoffStatus,
       CASE WHEN c.IsActive = 0 THEN N'Phase-1 table inactive: archiving already started - check manually'
            WHEN c.RetentionColumn <> p.RetentionColumn OR c.BlobPath <> LOWER(p.SchemaName + N'.' + p.TableName)
                 THEN N'Differs from FSD A.1 but archiving already started - not changed'
            ELSE N'OK' END AS CheckResult
FROM @Phase1 AS p
JOIN ret.RetentionConfig AS c ON c.SchemaName = p.SchemaName AND c.TableName = p.TableName
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
ORDER BY CASE c.SizeCategory WHEN 'SMALL' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END, c.TableConfigId;

SELECT c.IsActive, COUNT(*) AS Tables FROM ret.RetentionConfig AS c GROUP BY c.IsActive;
SELECT ArchiveContainer FROM ret.RetentionParameter WHERE ParameterSetId = 1;
GO
