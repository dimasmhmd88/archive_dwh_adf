/* =====================================================================================
   DWH Data Retention and Archiving - check that schema ret v0.6 is fully deployed
   -------------------------------------------------------------------------------------
   Script  : test/90_verify_v06_deployment.sql      Version 0.2 (DRAFT)      21 November 2026 (v0.6.1 checks)
   Read-only. Run after deploy/01..05. Every row of the result must show OK.

   Background: a database with the v0.6 tables and views but the v0.5 functions and procedures
   writes archive files in the old layout <BlobPath>/year=YYYY/month=MM/day=DD/<schema>_<table>_<yyyyMMdd>_<RunId>.parquet
   instead of <yyyy>/<BlobPath>/<BlobPath>_<yyyyMMdd>.parquet (MD-07), and the ADF v0.3 calls to
   usp_GetRunArchiveFiles and usp_GetExpiredArchiveFolders (levels YEAR / FILE) fail.
   ===================================================================================== */

SET NOCOUNT ON;

IF OBJECT_ID(N'tempdb..#Check') IS NOT NULL DROP TABLE #Check;
CREATE TABLE #Check (Ord INT IDENTITY(1, 1), CheckName NVARCHAR(200), Expected NVARCHAR(400), Actual NVARCHAR(400));

-- 1. Object counts (v0.6.2: 10 tables, 32 procedures, 10 functions, 8 views, 3 triggers)
INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'Object count ' + k.Kind, CONVERT(NVARCHAR(10), k.Expected), CONVERT(NVARCHAR(10), o.Cnt)
FROM (VALUES (N'TABLE', 10), (N'PROCEDURE', 32), (N'FUNCTION', 10), (N'VIEW', 8), (N'TRIGGER', 3)) AS k (Kind, Expected)
CROSS APPLY (SELECT COUNT(*) AS Cnt FROM sys.objects AS so
             WHERE so.schema_id = SCHEMA_ID(N'ret')
               AND CASE WHEN so.type = 'U' THEN N'TABLE' WHEN so.type = 'P' THEN N'PROCEDURE'
                        WHEN so.type IN ('FN', 'IF', 'TF') THEN N'FUNCTION' WHEN so.type = 'V' THEN N'VIEW'
                        WHEN so.type = 'TR' THEN N'TRIGGER' END = k.Kind) AS o;

-- 2. Archive layout functions (MD-07). v0.5 fn_ArchiveFileName has 4 parameters.
INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'fn_ArchiveFileName parameter count', N'2',
       CONVERT(NVARCHAR(10), COUNT(*)) FROM sys.parameters WHERE object_id = OBJECT_ID(N'ret.fn_ArchiveFileName') AND parameter_id > 0;

IF OBJECT_ID(N'ret.fn_ArchiveFolderPath') IS NOT NULL
    EXEC (N'INSERT INTO #Check (CheckName, Expected, Actual)
            VALUES (N''fn_ArchiveFolderPath(bos.jti_scw_stock, 2023-10-06)'', N''2023/bos.jti_scw_stock'',
                    ret.fn_ArchiveFolderPath(N''bos.jti_scw_stock'', ''2023-10-06''));');

IF (SELECT COUNT(*) FROM sys.parameters WHERE object_id = OBJECT_ID(N'ret.fn_ArchiveFileName') AND parameter_id > 0) = 2
    EXEC (N'INSERT INTO #Check (CheckName, Expected, Actual)
            VALUES (N''fn_ArchiveFileName(bos.jti_scw_stock, 2023-10-06)'', N''bos.jti_scw_stock_20231006.parquet'',
                    ret.fn_ArchiveFileName(N''bos.jti_scw_stock'', ''2023-10-06''));');

-- 2b. v0.6.1 (decision D-6): Parquet column names
IF OBJECT_ID(N'ret.fn_ParquetColumnName') IS NOT NULL
    EXEC (N'INSERT INTO #Check (CheckName, Expected, Actual)
            VALUES (N''fn_ParquetColumnName(Volume (000 STC))'', N''Volume_000_STC'', ret.fn_ParquetColumnName(N''Volume (000 STC)'')),
                   (N''fn_ParquetColumnName(Price Per Pack)'', N''Price_Per_Pack'', ret.fn_ParquetColumnName(N''Price Per Pack'')),
                   (N''fn_ParquetColumnName(dtmDate) unchanged'', N''dtmDate'', ret.fn_ParquetColumnName(N''dtmDate''));');
ELSE
    INSERT INTO #Check (CheckName, Expected, Actual) VALUES (N'Function ret.fn_ParquetColumnName (v0.6.1)', N'exists', N'missing');

-- 3. Objects and columns introduced in v0.6 (called by ADF pipeline-agus v0.3 / pipeline v0.3)
INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'Object ' + n.Name, N'exists', CASE WHEN OBJECT_ID(n.Name) IS NULL THEN N'missing' ELSE N'exists' END
FROM (VALUES (N'ret.usp_GetRunArchiveFiles'), (N'ret.usp_GetExpiredArchiveFolders'), (N'ret.usp_LogExpiredArchiveResult'),
             (N'ret.usp_PurgeTableLogs'), (N'ret.usp_PurgeRunLogs'), (N'ret.usp_ActivateDailyRoutine'),
             (N'ret.vw_MQ01_LatestRuns'), (N'ret.vw_MQ06_LocksAndRebuildTables'), (N'ret.vw_ParquetColumnMap'), (N'ret.vw_MQ07_ArchiveFiles')) AS n (Name);

INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'usp_GetExpiredArchiveFolders has @Level', N'yes',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(N'ret.usp_GetExpiredArchiveFolders') AND name = N'@Level')
            THEN N'yes' ELSE N'no' END;

INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'usp_IdentifyEligibleData contains D-1 check (ERR-EXP-02)', N'yes',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'ret.usp_IdentifyEligibleData')) LIKE N'%ERR-EXP-02%' THEN N'yes' ELSE N'no' END;

INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'Column RetentionConfig.LogRetentionYears', N'exists',
       CASE WHEN COL_LENGTH(N'ret.RetentionConfig', N'LogRetentionYears') IS NULL THEN N'missing' ELSE N'exists' END;

-- 4. Configuration values
INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'RetentionParameter.ArchiveContainer', N'dwh-archive', ISNULL(ArchiveContainer, N'NULL')
FROM ret.RetentionParameter WHERE ParameterSetId = 1;

INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'BlobPath values not lower-case <schema>.<table>', N'0', CONVERT(NVARCHAR(10), COUNT(*))
FROM ret.RetentionConfig
WHERE BlobPath COLLATE Latin1_General_100_BIN2 <> LOWER(SchemaName + N'.' + TableName) COLLATE Latin1_General_100_BIN2;

-- 5. Archive inventory written with the old layout (needs manual clean-up, see pipeline/sql/README.md)
INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'RetentionArchiveDate rows with old layout (not REMOVED)', N'0', CONVERT(NVARCHAR(10), COUNT(*))
FROM ret.RetentionArchiveDate
WHERE ExportStatus <> 'REMOVED' AND (FolderPath LIKE N'%/year=%' OR FolderPath NOT LIKE N'[12][0-9][0-9][0-9]/%');

SELECT Ord, CheckName, Expected, Actual, CASE WHEN Expected = Actual THEN 'OK' ELSE 'FAIL' END AS Result
FROM #Check ORDER BY Ord;

DROP TABLE #Check;
GO
