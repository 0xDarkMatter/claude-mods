import React from 'react';
import { Box, Text } from 'ink';
import { FileInfo, truncateFilename } from '../hooks/useDirectoryFiles.js';

interface FileSelectorProps {
  files: FileInfo[];
  currentFile: string;
  selectedIndex: number;
  isOpen: boolean;
  isFocused: boolean;
}

const MAX_DISPLAY_LENGTH = 30;

export const FileSelector: React.FC<FileSelectorProps> = ({
  files,
  currentFile,
  selectedIndex,
  isOpen,
  isFocused,
}) => {
  // Get current filename from path
  const currentFileName = currentFile.split(/[/\\]/).pop() || 'No file';
  const displayName = truncateFilename(currentFileName, MAX_DISPLAY_LENGTH);

  if (!isOpen) {
    // Closed state - just show current file with arrow
    return (
      <Text color="gray">
        {displayName} ▼
      </Text>
    );
  }

  // Open state - render as single text block to avoid Ink layout issues
  const lines: string[] = [];
  const pad = '   '; // Right padding

  // Current file
  lines.push(`${displayName} ▲${pad}`);

  // Separator
  lines.push(`─────────────────────${pad}`);

  // Show files or "no files" message
  if (files.length === 0) {
    lines.push(`  (no files in drafts/)${pad}`);
  } else {
    files.slice(0, 6).forEach((file, index) => {
      const isSelected = index === selectedIndex;
      const name = truncateFilename(file.name, MAX_DISPLAY_LENGTH);
      const marker = isSelected ? '▸' : ' ';
      lines.push(`${marker} ${name}${isSelected ? ' ◂' : '  '}${pad}`);
    });

    if (files.length > 6) {
      lines.push(`  +${files.length - 6} more${pad}`);
    }
  }

  return <Text>{lines.join('\n')}</Text>;
};
