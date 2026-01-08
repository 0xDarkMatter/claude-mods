import { useState, useEffect } from 'react';
import fs from 'fs';
import path from 'path';

export interface FileInfo {
  name: string;
  path: string;
  mtime: Date;
}

/**
 * Scans a directory for markdown and text files.
 * Returns sorted list (most recently modified first).
 */
export function useDirectoryFiles(dirPath: string): FileInfo[] {
  const [files, setFiles] = useState<FileInfo[]>([]);

  useEffect(() => {
    const scanDirectory = () => {
      try {
        // Resolve to absolute path, scan 'drafts' subdirectory
        const absoluteDir = path.resolve(dirPath);
        const draftsDir = path.join(absoluteDir, 'drafts');

        // Create drafts dir if it doesn't exist
        if (!fs.existsSync(draftsDir)) {
          fs.mkdirSync(draftsDir, { recursive: true });
        }

        const entries = fs.readdirSync(draftsDir, { withFileTypes: true });
        const fileInfos: FileInfo[] = [];

        for (const entry of entries) {
          if (!entry.isFile()) continue;

          const ext = path.extname(entry.name).toLowerCase();
          if (ext !== '.md' && ext !== '.txt') continue;

          const filePath = path.join(draftsDir, entry.name);
          const stats = fs.statSync(filePath);

          fileInfos.push({
            name: entry.name,
            path: filePath,
            mtime: stats.mtime,
          });
        }

        // Sort by modified time (most recent first)
        fileInfos.sort((a, b) => b.mtime.getTime() - a.mtime.getTime());
        setFiles(fileInfos);
      } catch (err) {
        // Directory might not exist yet
        setFiles([]);
      }
    };

    // Initial scan
    scanDirectory();

    // Re-scan periodically (every 2 seconds) to catch new files
    const interval = setInterval(scanDirectory, 2000);

    return () => clearInterval(interval);
  }, [dirPath]);

  return files;
}

/**
 * Format relative time for display (e.g., "now", "1h", "3d")
 */
export function formatRelativeTime(date: Date): string {
  const now = Date.now();
  const diff = now - date.getTime();

  const seconds = Math.floor(diff / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (seconds < 60) return 'now';
  if (minutes < 60) return `${minutes}m`;
  if (hours < 24) return `${hours}h`;
  if (days < 30) return `${days}d`;
  return `${Math.floor(days / 30)}mo`;
}

/**
 * Truncate filename to fit width, preserving extension
 */
export function truncateFilename(name: string, maxLength: number): string {
  if (name.length <= maxLength) return name;

  const ext = path.extname(name);
  const base = path.basename(name, ext);
  const availableLength = maxLength - ext.length - 3; // -3 for "..."

  if (availableLength <= 0) {
    return name.slice(0, maxLength - 3) + '...';
  }

  return base.slice(0, availableLength) + '...' + ext;
}
