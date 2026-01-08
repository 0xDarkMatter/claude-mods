import React from 'react';
import { Box, Text } from 'ink';
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
  const leftContent = ` ${title} `;

  // Get current filename from path
  const currentFileName = currentFile.split(/[/\\]/).pop() || 'No file';
  const displayName = truncateFilename(currentFileName, MAX_DISPLAY_LENGTH);

  // Filter out current file for dropdown
  const otherFiles = files.filter(f => f.path !== currentFile);

  return (
    <Box flexDirection="column">
      {/* Header bar - always single line with border */}
      <Box borderStyle="single" borderBottom={true} borderTop={false} borderLeft={false} borderRight={false}>
        <Box width={width}>
          <Text bold color="blue">{leftContent}</Text>
          <Box flexGrow={1} />
          <Text color="gray">{displayName} {isDropdownOpen ? '▲' : '▼'}</Text>
          <Text>    </Text>
        </Box>
      </Box>

      {/* Dropdown renders BELOW the header border */}
      {isDropdownOpen && (
        <Box justifyContent="flex-end" paddingRight={4}>
          <DropdownList
            files={otherFiles}
            selectedIndex={selectedFileIndex}
          />
        </Box>
      )}
    </Box>
  );
};

// Dropdown list component (only the list items, no header)
interface DropdownListProps {
  files: FileInfo[];
  selectedIndex: number;
}

const DropdownList: React.FC<DropdownListProps> = ({ files, selectedIndex }) => {
  const pad = '   ';

  if (files.length === 0) {
    return <Text color="gray">  (no other files){pad}</Text>;
  }

  const lines: string[] = [];

  // Subtle separator
  lines.push(`  · · ·${pad}`);

  // File list
  files.slice(0, 6).forEach((file, index) => {
    const isSelected = index === selectedIndex;
    const name = truncateFilename(file.name, MAX_DISPLAY_LENGTH);
    const marker = isSelected ? '▸' : ' ';
    lines.push(`${marker} ${name}${isSelected ? ' ◂' : '  '}${pad}`);
  });

  if (files.length > 6) {
    lines.push(`  +${files.length - 6} more${pad}`);
  }

  return <Text>{lines.join('\n')}</Text>;
};
