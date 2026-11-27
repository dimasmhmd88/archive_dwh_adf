/* =====================================================================================
   DWH Data Retention and Archiving - check that the OPSI B objects are deployed (read-only)
   -------------------------------------------------------------------------------------
   Script  : pipeline_opsi_B/sql/21_verify_opsiB.sql   Version 0.2 (DRAFT)   27 November 2026
   0.2: checks of ChildDeleteMode (D-8, SQL v0.7.1-opsiB) and index check of child tables.
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
FROM (VALUES (N'CK_RetentionParameter_ExportParallelism'), (N'CK_RetentionConfig_ExportParallelism'),
             (N'CK_RetentionParameter_ChildDeleteMode')) AS c (Name)
UNION ALL
SELECT N'Column RetentionParameter.ChildDeleteMode', N'exists',
       CASE WHEN COL_LENGTH(N'ret.RetentionParameter', N'ChildDeleteMode') IS NULL THEN N'missing' ELSE N'exists' END
UNION ALL
SELECT N'usp_BatchDelete version v0.7.1-opsiB (KEY_TABLE)', N'yes',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'ret.usp_BatchDelete')) LIKE N'%#RetBdParentKey%' THEN N'yes' ELSE N'no' END;

-- 4. v0.6 deployment still complete (procedures: 32 + 6 new)
INSERT INTO #Check (CheckName, Expected, Actual)
SELECT N'Procedure count schema ret', N'38', CONVERT(NVARCHAR(10), COUNT(*))
FROM sys.procedures WHERE schema_id = SCHEMA_ID(N'ret');

SELECT Ord, CheckName, Expected, Actual, CASE WHEN Expected = Actual THEN 'OK' ELSE 'FAIL' END AS Result
FROM #Check ORDER BY Ord;
DROP TABLE #Check;

-- 5. Current export parallelism (N) and child delete mode: global and per-table overrides
IF COL_LENGTH(N'ret.RetentionParameter', N'ExportParallelism') IS NOT NULL
    EXEC (N'SELECT ExportParallelism AS GlobalExportParallelism FROM ret.RetentionParameter WHERE ParameterSetId = 1;
            SELECT TableConfigId, SchemaName, TableName, SizeCategory, ExportParallelism AS TableOverride
            FROM ret.RetentionConfig WHERE ExportParallelism IS NOT NULL ORDER BY TableConfigId;');
IF COL_LENGTH(N'ret.RetentionParameter', N'ChildDeleteMode') IS NOT NULL
    EXEC (N'SELECT ChildDeleteMode, BatchSize, BatchPauseSeconds FROM ret.RetentionParameter WHERE ParameterSetId = 1;');

-- 6. Child tables: index on the join key (child) and on the header key (information; "missing" = every batch
--    scans the child table, in JOIN and in KEY_TABLE mode). Leading index column = first join key column.
SELECT c.TableConfigId, c.SchemaName + N'.' + c.TableName AS ChildTable, h.SchemaName + N'.' + h.TableName AS HeaderTable,
       k.ChildColumn AS FirstChildKey, k.ParentColumn AS FirstHeaderKey,
       CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns AS ic JOIN sys.columns AS col
                                ON col.object_id = ic.object_id AND col.column_id = ic.column_id
                         WHERE ic.object_id = OBJECT_ID(QUOTENAME(c.SchemaName) + N'.' + QUOTENAME(c.TableName))
                           AND ic.key_ordinal = 1 AND col.name COLLATE DATABASE_DEFAULT = k.ChildColumn)
            THEN N'yes' ELSE N'missing' END AS ChildKeyIndex,
       CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns AS ic JOIN sys.columns AS col
                                ON col.object_id = ic.object_id AND col.column_id = ic.column_id
                         WHERE ic.object_id = OBJECT_ID(QUOTENAME(h.SchemaName) + N'.' + QUOTENAME(h.TableName))
                           AND ic.key_ordinal = 1 AND col.name COLLATE DATABASE_DEFAULT = h.RetentionColumn)
            THEN N'yes' ELSE N'missing' END AS HeaderDateIndex
FROM ret.RetentionConfig AS c
JOIN ret.RetentionConfig AS h ON h.TableConfigId = c.ParentTableConfigId
LEFT JOIN ret.RetentionParentKey AS k ON k.TableConfigId = c.TableConfigId AND k.KeyOrdinal = 1
WHERE c.ParentTableConfigId IS NOT NULL
ORDER BY c.TableConfigId;
GO
