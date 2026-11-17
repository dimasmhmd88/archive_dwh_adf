/* =====================================================================================
   DWH Data Retention and Archiving - check that the OPSI B objects are deployed (read-only)
   -------------------------------------------------------------------------------------
   Script  : pipeline_opsi_B/sql/21_verify_opsiB.sql   Version 0.1 (DRAFT)   17 November 2026
   Run after 20_OpsiB_DB_Objects.sql. Every row must show OK.
   ===================================================================================== */
SET NOCOUNT ON;

IF OBJECT_ID(N'tempdb..#Check') IS NOT NULL DROP TABLE #Check;
CREATE TABLE #Check (Ord INT IDENTITY(1, 1), CheckName NVARCHAR(200), Expected NVARCHAR(400), Actual NVARCHAR(400));

-- 1. New procedures
INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'Procedure ' + n.Name, N'exists', CASE WHEN OBJECT_ID(n.Name, N'P') IS NULL THEN N'missing' ELSE N'exists' END
FROM (VALUES (N'ret.usp_StartRunAndGetTables'), (N'ret.usp_BeginTableAndIdentify'), (N'ret.usp_GetExportChunk'),
             (N'ret.usp_ValidateDeleteAndCheck'), (N'ret.usp_GetCleanupDecision'), (N'ret.usp_GetExpiredArchiveItems')) AS n (Name);

-- 2. v0.6 procedures with the #RetOut_ output option
INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'#RetOut_ option in ' + n.Name, N'yes',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID(n.Name)) LIKE N'%#RetOut[_]%' THEN N'yes' ELSE N'no' END
FROM (VALUES (N'ret.usp_StartRun'), (N'ret.usp_GetTablesToProcess'), (N'ret.usp_BeginTable'), (N'ret.usp_IdentifyEligibleData'),
             (N'ret.usp_ValidateArchive'), (N'ret.usp_BatchDelete'), (N'ret.usp_PostCheck'),
             (N'ret.usp_GetExpiredArchiveFolders'), (N'ret.usp_EndRun')) AS n (Name);

-- 3. Columns and constraints
INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'Column RetentionParameter.ExportParallelism', N'exists',
       CASE WHEN COL_LENGTH(N'ret.RetentionParameter', N'ExportParallelism') IS NULL THEN N'missing' ELSE N'exists' END
UNION ALL
SELECT N'Column RetentionConfig.ExportParallelism', N'exists',
       CASE WHEN COL_LENGTH(N'ret.RetentionConfig', N'ExportParallelism') IS NULL THEN N'missing' ELSE N'exists' END
UNION ALL
SELECT N'Constraint ' + c.Name, N'exists', CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = c.Name) THEN N'exists' ELSE N'missing' END
FROM (VALUES (N'CK_RetentionParameter_ExportParallelism'), (N'CK_RetentionConfig_ExportParallelism')) AS c (Name);

-- 4. v0.6 deployment still complete (procedures: 32 + 6 new)
INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'Procedure count schema ret', N'38', CONVERT(NVARCHAR(10), COUNT(*))
FROM sys.procedures WHERE schema_id = SCHEMA_ID(N'ret');

SELECT Ord, CheckName, Expected, Actual, CASE WHEN Expected = Actual THEN 'OK' ELSE 'FAIL' END AS Result
FROM #Check ORDER BY Ord;
DROP TABLE #Check;

-- 5. Current export parallelism (N): global and per-table overrides
IF COL_LENGTH(N'ret.RetentionParameter', N'ExportParallelism') IS NOT NULL
    EXEC (N'SELECT ExportParallelism AS GlobalExportParallelism FROM ret.RetentionParameter WHERE ParameterSetId = 1;
            SELECT TableConfigId, SchemaName, TableName, SizeCategory, ExportParallelism AS TableOverride
            FROM ret.RetentionConfig WHERE ExportParallelism IS NOT NULL ORDER BY TableConfigId;');
GO
