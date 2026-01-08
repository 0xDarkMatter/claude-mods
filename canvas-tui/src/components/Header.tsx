import React from 'react';
import { Box, Text } from 'ink';
import { FileSelector } from './FileSelector.js';
import { FileInfo } from '../hooks/useDirectoryFiles.js';

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

  // Reserve space for file selector (~30 chars)
  const selectorWidth = 30;
  const padding = Math.max(0, width - leftContent.length - selectorWidth - 2);

  return (
    <Box flexDirection="column">
      <Box borderStyle="single" borderBottom={true} borderTop={false} borderLeft={false} borderRight={false}>
        <Box width={width} justifyContent="space-between">
          <Text bold color="blue">{leftContent}</Text>
          <Text>{' '.repeat(padding)}</Text>
          <FileSelector
            files={files}
            currentFile={currentFile}
            selectedIndex={selectedFileIndex}
            isOpen={isDropdownOpen}
            isFocused={isDropdownFocused}
          />
        </Box>
      </Box>
    </Box>
  );
};
