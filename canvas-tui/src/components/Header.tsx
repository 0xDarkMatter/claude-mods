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

  return (
    <Box flexDirection="column">
      {/* Header bar */}
      <Box borderStyle="single" borderBottom={true} borderTop={false} borderLeft={false} borderRight={false}>
        <Box width={width}>
          <Text bold color="blue">{leftContent}</Text>
          <Box flexGrow={1} />
          <FileSelector
            files={files}
            currentFile={currentFile}
            selectedIndex={selectedFileIndex}
            isOpen={isDropdownOpen}
            isFocused={isDropdownFocused}
          />
          <Text>    </Text>
        </Box>
      </Box>
    </Box>
  );
};
