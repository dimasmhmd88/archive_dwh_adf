/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - PATCH v0.6.2 (monitoring view MQ-07)
   -------------------------------------------------------------------------------------
   Script  : pipeline/sql/deploy/09_patch_v0.6.2_view_archive_files.sql
   Version : 0.6.2 (DRAFT - not reviewed, not executed against any database)   Date: 23 November 2026
   Content : ret.vw_MQ07_ArchiveFiles - row counts per Parquet file (DWH / read / written), path, status, duration
   Apply to: databases already on v0.6 / v0.6.1. New deployments: deploy/05 already contains the view.
             Independent of opsi B (no procedure changed).
   ===================================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- MQ-07 Archive files: row counts per Parquet file (one row per table log and business date, v0.6.2).
-- RowCountDwh = rows in the DWH at the snapshot, RowCountRead / RowCountParquet = ADF Copy rowsRead / rowsCopied.
CREATE OR ALTER VIEW ret.vw_MQ07_ArchiveFiles
AS
SELECT a.RunId, r.ProcessType, r.RunDate AS ProcessDate, r.TriggeredBy,
       a.TableLogId, a.TableConfigId, c.SchemaName, c.TableName,
       a.BusinessDate AS DataDate,
       a.ExpectedRows AS RowCountDwh,
       a.RowsRead     AS RowCountRead,
       a.RowsWritten  AS RowCountParquet,
       a.RowsWritten - a.ExpectedRows AS RowDifference,
       CAST(CASE WHEN a.ExportStatus = 'SUCCEEDED' AND a.RowsRead = a.ExpectedRows AND a.RowsWritten = a.ExpectedRows
                 THEN 1 ELSE 0 END AS BIT) AS RowCountMatch,
       a.FileCount, a.ExportStatus, a.ValidationResult,
       p.ArchiveContainer AS Container, a.FolderPath, a.FileName,
       p.ArchiveContainer + N'/' + a.FolderPath + N'/' + a.FileName AS FilePath,
       a.ExportStartTime, a.ExportEndTime,
       DATEDIFF(SECOND, a.ExportStartTime, a.ExportEndTime) AS ExportSeconds,
       a.ErrorMessage
FROM ret.RetentionArchiveDate AS a
JOIN ret.RetentionRunLog AS r ON r.RunId = a.RunId
JOIN ret.RetentionConfig AS c ON c.TableConfigId = a.TableConfigId
CROSS JOIN ret.RetentionParameter AS p
WHERE p.ParameterSetId = 1;
GO

-- Check: files of the last run
SELECT TOP (50) * FROM ret.vw_MQ07_ArchiveFiles
WHERE RunId = (SELECT MAX(RunId) FROM ret.RetentionArchiveDate)
ORDER BY SchemaName, TableName, DataDate;
GO
