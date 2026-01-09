import React, { useEffect } from 'react';
import { Box, Text, useStdout } from 'ink';
import { FileInfo, truncateFilename } from '../hooks/useDirectoryFiles.js';

interface HeaderProps {
  title: string;
  width: number;
  // File selector props
  files: FileInfo[];
  currentFile: string;
  selectedFileIndex: number;
  isDropdownOpen: boolean;
  isDropdownFocused: boolean;
}

const MAX_DISPLAY_LENGTH = 30;

export const Header: React.FC<HeaderProps> = ({
  title,
  width,
  files,
  currentFile,
  selectedFileIndex,
  isDropdownOpen,
  isDropdownFocused,
}) => {
  const { stdout } = useStdout();
  const leftContent = ` ${title} `;

  // Get current filename from path
  const currentFileName = currentFile.split(/[/\\]/).pop() || 'No file';
  const displayName = truncateFilename(currentFileName, MAX_DISPLAY_LENGTH);

  // Filter out current file for dropdown
  const otherFiles = files.filter(f => f.path !== currentFile);

  // Render dropdown as overlay using ANSI escape codes
  useEffect(() => {
    if (!isDropdownOpen || !stdout) return;

    const cols = stdout.columns || 80;
    const startRow = 3; // Below header border line

    // Build dropdown content (right-aligned)
    const lines: string[] = [];

    if (otherFiles.length === 0) {
      lines.push('(no other files)');
    } else {
      otherFiles.slice(0, 6).forEach((file, index) => {
        const isSelected = index === selectedFileIndex;
        const name = truncateFilename(file.name, MAX_DISPLAY_LENGTH);
        if (isSelected) {
          // Reversed video for selected item
          lines.push(`\x1B[7m ${name} \x1B[0m`);
        } else {
          // Dim text for unselected
          lines.push(`\x1B[2m ${name} \x1B[0m`);
        }
      });

      if (otherFiles.length > 6) {
        lines.push(`\x1B[2m +${otherFiles.length - 6} more \x1B[0m`);
      }
    }

    // Find max line length for right-alignment
    const maxLen = Math.max(...lines.map(l => l.replace(/\x1B\[[0-9;]*m/g, '').length));

    // Save cursor, render dropdown at absolute position (right-aligned), restore cursor
    let output = '\x1B[s'; // Save cursor position

    lines.forEach((line, idx) => {
      const row = startRow + idx;
      const plainLen = line.replace(/\x1B\[[0-9;]*m/g, '').length;
      const padding = maxLen - plainLen;
      const startCol = cols - maxLen - 1; // Right margin of 1 (matches header padding)
      output += `\x1B[${row};${startCol}H${' '.repeat(padding)}${line}`;
    });

    output += '\x1B[u'; // Restore cursor position

    process.stdout.write(output);

    // Cleanup: clear the dropdown area when closing
    return () => {
      let clear = '\x1B[s';
      lines.forEach((_, idx) => {
        const row = startRow + idx;
        const startCol = cols - maxLen - 1;
        clear += `\x1B[${row};${startCol}H${' '.repeat(maxLen + 1)}`;
      });
      clear += '\x1B[u';
      process.stdout.write(clear);
    };
  }, [isDropdownOpen, selectedFileIndex, otherFiles, stdout]);

  return (
    <Box flexDirection="column">
      {/* Header bar - always single line with border */}
      <Box borderStyle="single" borderBottom={true} borderTop={false} borderLeft={false} borderRight={false} borderDimColor>
        <Box width={width}>
          <Text bold color="blue">{leftContent}</Text>
          <Box flexGrow={1} />
          <Text color="white" dimColor>{displayName} {isDropdownOpen ? '▲' : '▼'}</Text>
          <Text> </Text>
        </Box>
      </Box>
    </Box>
  );
};
