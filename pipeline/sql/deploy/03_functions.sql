/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - 03_functions.sql
   Part of DWH_Retention_DB_Objects_v0.5.sql, v0.5.1 collation fix (DRAFT - not reviewed, not executed against any database).
   Functions (section 4)
   Deploy order: see pipeline/sql/README.md. Run connected to the DWH database.
   ===================================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

/* =====================================================================================
   4. FUNCTIONS (design table v0.2)
   ===================================================================================== */

-- Current date-time in UTC+7 (BR-04). Azure SQL Database runs in UTC; WIB has no DST.
CREATE OR ALTER FUNCTION ret.fn_NowUtc7 ()
RETURNS DATETIME2(3)
AS
BEGIN
    RETURN CONVERT(DATETIME2(3), DATEADD(HOUR, 7, SYSUTCDATETIME()));
END;
GO

CREATE OR ALTER FUNCTION ret.fn_TodayUtc7 ()
RETURNS DATE
AS
BEGIN
    RETURN CONVERT(DATE, DATEADD(HOUR, 7, SYSUTCDATETIME()));
END;
GO

-- Cut-off dates (BR-03): total = DWH + Blob years; e.g. 2026-10-27, 3 + 5 -> 2023-10-27 / 2018-10-27
CREATE OR ALTER FUNCTION ret.fn_GetCutoffDates
(
    @RunDate                DATE,
    @DwhRetentionYears      SMALLINT,
    @BlobRetentionYears     SMALLINT
)
RETURNS TABLE
AS
RETURN
    SELECT CONVERT(SMALLINT, @DwhRetentionYears + @BlobRetentionYears)              AS TotalRetentionYears,
           DATEADD(YEAR, -@DwhRetentionYears, @RunDate)                              AS DwhCutoffDate,
           DATEADD(YEAR, -(@DwhRetentionYears + @BlobRetentionYears), @RunDate)      AS ArchiveCutoffDate;
GO

-- Window that may cross midnight (BR-17: 21:00 - 05:00)
CREATE OR ALTER FUNCTION ret.fn_IsWithinWindow
(
    @Time           TIME(0),
    @WindowStart    TIME(0),
    @WindowEnd      TIME(0)
)
RETURNS BIT
AS
BEGIN
    RETURN CASE
        WHEN @Time IS NULL OR @WindowStart IS NULL OR @WindowEnd IS NULL THEN CAST(0 AS BIT)
        WHEN @WindowStart = @WindowEnd THEN CAST(1 AS BIT)
        WHEN @WindowStart < @WindowEnd
            THEN CASE WHEN @Time >= @WindowStart AND @Time < @WindowEnd THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END
        ELSE CASE WHEN @Time >= @WindowStart OR @Time < @WindowEnd THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END
    END;
END;
GO

-- Archive folder <BlobPath>/year=YYYY/month=MM/day=DD (MD-07)
CREATE OR ALTER FUNCTION ret.fn_ArchiveFolderPath
(
    @BlobPath       NVARCHAR(400),
    @BusinessDate   DATE
)
RETURNS NVARCHAR(1024)
AS
BEGIN
    DECLARE @d NCHAR(8) = CONVERT(NCHAR(8), @BusinessDate, 112);   -- yyyyMMdd
    RETURN @BlobPath + N'/year=' + SUBSTRING(@d, 1, 4) + N'/month=' + SUBSTRING(@d, 5, 2) + N'/day=' + SUBSTRING(@d, 7, 2);
END;
GO

-- Archive file name with RunId; never overwritten (DBR-07)
CREATE OR ALTER FUNCTION ret.fn_ArchiveFileName
(
    @SchemaName     SYSNAME,
    @TableName      SYSNAME,
    @BusinessDate   DATE,
    @RunId          BIGINT
)
RETURNS NVARCHAR(400)
AS
BEGIN
    RETURN @SchemaName + N'_' + @TableName + N'_' + CONVERT(NCHAR(8), @BusinessDate, 112)
         + N'_' + CONVERT(NVARCHAR(20), @RunId) + N'.parquet';
END;
GO

-- Seconds -> 'hh:mm:ss' for WAITFOR DELAY
CREATE OR ALTER FUNCTION ret.fn_DelayString (@Seconds INT)
RETURNS CHAR(8)
AS
BEGIN
    RETURN CONVERT(CHAR(8), DATEADD(SECOND, ISNULL(@Seconds, 0), CAST('00:00:00' AS TIME(0))), 108);
END;
GO

-- Column data type as T-SQL text (used to script the new table of a rebuild, RB-02)
CREATE OR ALTER FUNCTION ret.fn_ColumnTypeSql
(
    @UserTypeId INT,
    @MaxLength  SMALLINT,
    @Precision  TINYINT,
    @Scale      TINYINT
)
RETURNS NVARCHAR(300)
AS
BEGIN
    DECLARE @Name SYSNAME, @SchemaName SYSNAME, @IsUserDefined BIT;

    SELECT @Name = t.name COLLATE DATABASE_DEFAULT, @SchemaName = SCHEMA_NAME(t.schema_id), @IsUserDefined = t.is_user_defined
    FROM sys.types AS t
    WHERE t.user_type_id = @UserTypeId;

    IF @IsUserDefined = 1
        RETURN QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@Name);

    RETURN @Name + CASE
        WHEN @Name IN (N'varchar', N'char', N'varbinary', N'binary')
            THEN N'(' + CASE WHEN @MaxLength = -1 THEN N'MAX' ELSE CONVERT(NVARCHAR(10), @MaxLength) END + N')'
        WHEN @Name IN (N'nvarchar', N'nchar')
            THEN N'(' + CASE WHEN @MaxLength = -1 THEN N'MAX' ELSE CONVERT(NVARCHAR(10), @MaxLength / 2) END + N')'
        WHEN @Name IN (N'decimal', N'numeric') THEN CONCAT(N'(', @Precision, N', ', @Scale, N')')
        WHEN @Name IN (N'datetime2', N'time', N'datetimeoffset') THEN CONCAT(N'(', @Scale, N')')
        WHEN @Name = N'float' THEN CONCAT(N'(', @Precision, N')')
        ELSE N''
    END;
END;
GO

-- Text description of a table definition (columns, indexes, constraints, triggers, permissions).
-- Compared before and after the rebuild (RB-10). Object IDs are not part of the text.
CREATE OR ALTER FUNCTION ret.fn_TableDefinitionText (@ObjectId INT)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @Cols NVARCHAR(MAX), @Idx NVARCHAR(MAX), @Chk NVARCHAR(MAX), @Def NVARCHAR(MAX),
            @Fk NVARCHAR(MAX), @Trg NVARCHAR(MAX), @Perm NVARCHAR(MAX);

    SELECT @Cols = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(c.name COLLATE DATABASE_DEFAULT, N'|', TYPE_NAME(c.user_type_id), N'|', c.max_length, N'|',
                   c.precision, N'|', c.scale, N'|', c.is_nullable, N'|', c.collation_name COLLATE DATABASE_DEFAULT, N'|', c.is_identity, N'|',
                   cc.definition COLLATE DATABASE_DEFAULT, N'|', cc.is_persisted)) COLLATE DATABASE_DEFAULT, N';') WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns AS c
    LEFT JOIN sys.computed_columns AS cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
    WHERE c.object_id = @ObjectId;

    SELECT @Idx = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(i.name COLLATE DATABASE_DEFAULT, N'|', i.type, N'|', i.is_unique, N'|', i.is_primary_key, N'|',
                  i.is_unique_constraint, N'|', i.filter_definition COLLATE DATABASE_DEFAULT, N'|', i.is_disabled, N'|', i.fill_factor, N'|',
                  i.ignore_dup_key, N'|', k.Cols, N'|', pz.Compression)) COLLATE DATABASE_DEFAULT, N';') WITHIN GROUP (ORDER BY i.type, i.name COLLATE DATABASE_DEFAULT)
    FROM sys.indexes AS i
    OUTER APPLY (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(c.name COLLATE DATABASE_DEFAULT, CASE WHEN ic.is_descending_key = 1 THEN N' DESC' END,
                        CASE WHEN ic.is_included_column = 1 THEN N' INCLUDE' END)) COLLATE DATABASE_DEFAULT, N',') WITHIN GROUP (ORDER BY ic.key_ordinal, ic.index_column_id) AS Cols
                 FROM sys.index_columns AS ic
                 JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id) AS k
    OUTER APPLY (SELECT MIN(p.data_compression_desc COLLATE DATABASE_DEFAULT) AS Compression
                 FROM sys.partitions AS p WHERE p.object_id = i.object_id AND p.index_id = i.index_id) AS pz
    WHERE i.object_id = @ObjectId;

    SELECT @Chk = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(ck.name COLLATE DATABASE_DEFAULT, N'|', ck.definition COLLATE DATABASE_DEFAULT, N'|', ck.is_disabled, N'|', ck.is_not_trusted)) COLLATE DATABASE_DEFAULT, N';')
                  WITHIN GROUP (ORDER BY ck.name COLLATE DATABASE_DEFAULT)
    FROM sys.check_constraints AS ck
    WHERE ck.parent_object_id = @ObjectId;

    SELECT @Def = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(dc.name COLLATE DATABASE_DEFAULT, N'|', c.name COLLATE DATABASE_DEFAULT, N'|', dc.definition COLLATE DATABASE_DEFAULT)), N';') WITHIN GROUP (ORDER BY dc.name COLLATE DATABASE_DEFAULT)
    FROM sys.default_constraints AS dc
    JOIN sys.columns AS c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = @ObjectId;

    SELECT @Fk = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(fk.name COLLATE DATABASE_DEFAULT, N'|', OBJECT_SCHEMA_NAME(fk.referenced_object_id), N'.',
                 OBJECT_NAME(fk.referenced_object_id), N'|', fk.delete_referential_action, N'|', fk.update_referential_action, N'|',
                 fk.is_disabled, N'|', fk.is_not_trusted, N'|', fc.Cols)) COLLATE DATABASE_DEFAULT, N';') WITHIN GROUP (ORDER BY fk.name COLLATE DATABASE_DEFAULT)
    FROM sys.foreign_keys AS fk
    OUTER APPLY (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(COL_NAME(x.parent_object_id, x.parent_column_id), N'>',
                        COL_NAME(x.referenced_object_id, x.referenced_column_id))) COLLATE DATABASE_DEFAULT, N',') WITHIN GROUP (ORDER BY x.constraint_column_id) AS Cols
                 FROM sys.foreign_key_columns AS x WHERE x.constraint_object_id = fk.object_id) AS fc
    WHERE fk.parent_object_id = @ObjectId;

    SELECT @Trg = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(tr.name COLLATE DATABASE_DEFAULT, N'|', tr.is_disabled, N'|', tr.is_instead_of_trigger)) COLLATE DATABASE_DEFAULT, N';')
                  WITHIN GROUP (ORDER BY tr.name COLLATE DATABASE_DEFAULT)
    FROM sys.triggers AS tr
    WHERE tr.parent_id = @ObjectId;

    SELECT @Perm = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(dp.state_desc COLLATE DATABASE_DEFAULT, N'|', dp.permission_name COLLATE DATABASE_DEFAULT, N'|', USER_NAME(dp.grantee_principal_id),
                   N'|', COL_NAME(dp.major_id, NULLIF(dp.minor_id, 0)))) COLLATE DATABASE_DEFAULT, N';')
                   WITHIN GROUP (ORDER BY dp.state_desc COLLATE DATABASE_DEFAULT, dp.permission_name COLLATE DATABASE_DEFAULT, dp.grantee_principal_id, dp.minor_id)
    FROM sys.database_permissions AS dp
    WHERE dp.class = 1 AND dp.major_id = @ObjectId;

    RETURN CONCAT(N'COLUMNS:', @Cols, N'#INDEXES:', @Idx, N'#CHECKS:', @Chk, N'#DEFAULTS:', @Def,
                  N'#FK:', @Fk, N'#TRIGGERS:', @Trg, N'#PERMISSIONS:', @Perm);
END;
GO
