/* =====================================================================================
   DWH Data Retention and Archiving - check of the child delete mode KEY_TABLE (read-only, D-8)
   -------------------------------------------------------------------------------------
   Script  : SQL_Script/verify/22_check_child_delete_mode.sql   Version 0.1 (DRAFT)   27 November 2026
   Requires: 20_OpsiB_DB_Objects.sql v0.7.1-opsiB
   Purpose : before switching ChildDeleteMode to KEY_TABLE (and after a run), prove for ONE child table that
             both methods select the same child rows for a cut-off:
               JOIN      : child LEFT JOIN header, header date < @Cutoff          (v0.6, validated count)
               KEY_TABLE : distinct header keys with date < @Cutoff, child JOIN keys (opsi B v0.7.1)
             Nothing is changed. Duplicate header keys (V-11) make the two counts differ: fix those first.
   Settings: @TableConfigId = the CHILD table; @Cutoff = DWH cut-off (NULL = RunDate today - DwhRetentionYears).
   ===================================================================================== */
SET NOCOUNT ON;

DECLARE @TableConfigId INT  = NULL;     -- <- child TableConfigId
DECLARE @Cutoff        DATE = NULL;     -- <- NULL = today (UTC+7) minus DwhRetentionYears

DECLARE @IsChild BIT, @FullName NVARCHAR(300), @DateTableFullName NVARCHAR(300), @DateExpr NVARCHAR(400), @FromSql NVARCHAR(MAX),
        @Err VARCHAR(12), @Chk VARCHAR(4), @Msg NVARCHAR(4000), @Years SMALLINT,
        @KeySel NVARCHAR(MAX), @KeyNotNull NVARCHAR(MAX), @KeyOnSub NVARCHAR(MAX), @sql NVARCHAR(MAX),
        @JoinRows BIGINT, @KeyRows BIGINT, @Keys BIGINT, @Orphans BIGINT, @t0 DATETIME2(3), @msJoin INT, @msKey INT;

IF @TableConfigId IS NULL
BEGIN
    SELECT c.TableConfigId, c.SchemaName + N'.' + c.TableName AS ChildTable, c.ParentTableConfigId,
           h.SchemaName + N'.' + h.TableName AS HeaderTable, c.IsActive
    FROM ret.RetentionConfig AS c JOIN ret.RetentionConfig AS h ON h.TableConfigId = c.ParentTableConfigId
    ORDER BY c.TableConfigId;
    RAISERROR (N'Set @TableConfigId to one of the child tables listed above.', 0, 1) WITH NOWAIT;
    RETURN;
END;

EXEC ret.usp_GetTableSqlParts @TableConfigId = @TableConfigId, @CheckUniqueness = 2,
     @IsChild = @IsChild OUTPUT, @FullName = @FullName OUTPUT, @DateTableFullName = @DateTableFullName OUTPUT,
     @DateExpr = @DateExpr OUTPUT, @FromSql = @FromSql OUTPUT, @ErrorCode = @Err OUTPUT, @CheckCode = @Chk OUTPUT,
     @ErrorMessage = @Msg OUTPUT;

IF @Err IS NOT NULL OR @IsChild = 0
BEGIN
    SELECT ISNULL(@Err, 'NOT CHILD') AS ErrorCode, @Chk AS CheckCode,
           ISNULL(@Msg, N'TableConfigId is not a child table; ChildDeleteMode does not apply.') AS Message;
    RETURN;
END;

SELECT @Years = DwhRetentionYears FROM ret.RetentionConfig WHERE TableConfigId = @TableConfigId;
SET @Cutoff = ISNULL(@Cutoff, DATEADD(YEAR, -@Years, CAST(DATEADD(HOUR, 7, SYSUTCDATETIME()) AS DATE)));

SELECT @KeySel     = STRING_AGG(CONVERT(NVARCHAR(MAX), N'p.' + QUOTENAME(ParentColumn)) COLLATE DATABASE_DEFAULT, N', ')
                     WITHIN GROUP (ORDER BY KeyOrdinal),
       @KeyNotNull = STRING_AGG(CONVERT(NVARCHAR(MAX), N'p.' + QUOTENAME(ParentColumn) + N' IS NOT NULL') COLLATE DATABASE_DEFAULT, N' AND ')
                     WITHIN GROUP (ORDER BY KeyOrdinal),
       @KeyOnSub   = STRING_AGG(CONVERT(NVARCHAR(MAX), N'k.' + QUOTENAME(ParentColumn) + N' = t.' + QUOTENAME(ChildColumn)) COLLATE DATABASE_DEFAULT, N' AND ')
                     WITHIN GROUP (ORDER BY KeyOrdinal)
FROM ret.RetentionParentKey WHERE TableConfigId = @TableConfigId;

-- 1. JOIN (v0.6 method)
SET @t0 = SYSDATETIME();
SET @sql = N'SELECT @n = COUNT_BIG(*)' + @FromSql + N' WHERE ' + @DateExpr + N' < @Upper;';
EXEC sp_executesql @sql, N'@Upper DATE, @n BIGINT OUTPUT', @Upper = @Cutoff, @n = @JoinRows OUTPUT;
SET @msJoin = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());

-- 2. KEY_TABLE (distinct header keys, then child join)
SET @t0 = SYSDATETIME();
SET @sql = N'SELECT @k = COUNT_BIG(*) FROM (SELECT DISTINCT ' + @KeySel + N' FROM ' + @DateTableFullName + N' AS p
WHERE ' + @DateExpr + N' < @Upper AND ' + @KeyNotNull + N') AS q;
SELECT @n = COUNT_BIG(*) FROM ' + @FullName + N' AS t
JOIN (SELECT DISTINCT ' + @KeySel + N' FROM ' + @DateTableFullName + N' AS p
      WHERE ' + @DateExpr + N' < @Upper AND ' + @KeyNotNull + N') AS k ON ' + @KeyOnSub + N';';
EXEC sp_executesql @sql, N'@Upper DATE, @k BIGINT OUTPUT, @n BIGINT OUTPUT',
     @Upper = @Cutoff, @k = @Keys OUTPUT, @n = @KeyRows OUTPUT;
SET @msKey = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());

-- 3. Orphan child rows (never deleted or archived, DBR-21)
SET @sql = N'SELECT @n = COUNT_BIG(*)' + @FromSql + N' WHERE ' + @DateExpr + N' IS NULL;';
EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @Orphans OUTPUT;

SELECT @TableConfigId AS TableConfigId, @FullName AS ChildTable, @DateTableFullName AS HeaderTable,
       CONVERT(CHAR(10), @Cutoff, 23) AS Cutoff,
       @JoinRows AS ChildRows_JOIN, @KeyRows AS ChildRows_KEY_TABLE, @Keys AS HeaderKeys, @Orphans AS OrphanChildRows,
       @msJoin AS CountMs_JOIN, @msKey AS CountMs_KEY_TABLE,
       CASE WHEN @JoinRows = @KeyRows THEN 'OK' ELSE 'FAIL' END AS Result,
       CASE WHEN @JoinRows = @KeyRows THEN N'Both methods select the same child rows.'
            ELSE N'Counts differ: check duplicate header keys (V-11) before using KEY_TABLE.' END AS Message;

-- 4. Current setting
IF COL_LENGTH(N'ret.RetentionParameter', N'ChildDeleteMode') IS NOT NULL
    EXEC (N'SELECT ChildDeleteMode, BatchSize, BatchPauseSeconds FROM ret.RetentionParameter WHERE ParameterSetId = 1;');
GO
