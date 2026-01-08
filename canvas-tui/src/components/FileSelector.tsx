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

const MAX_DISPLAY_LENGTH = 20;

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

  return (
    <Box flexDirection="column" alignItems="flex-end">
      {/* Selector - just filename with arrow */}
      <Text
        inverse={isFocused}
        color={isFocused ? undefined : 'gray'}
      >
        {displayName} {isOpen ? '▲' : '▼'}
      </Text>

      {/* Dropdown - simple list */}
      {isOpen && files.length > 0 && (
        <Box flexDirection="column" marginTop={0}>
          {files.slice(0, 6).map((file, index) => {
            const isSelected = index === selectedIndex;
            const isCurrent = file.name === currentFileName;
            const name = truncateFilename(file.name, MAX_DISPLAY_LENGTH);

            return (
              <Text
                key={file.path}
                inverse={isSelected}
                color={isCurrent && !isSelected ? 'cyan' : undefined}
              >
                {isSelected ? '› ' : '  '}{name}
              </Text>
            );
          })}
          {files.length > 6 && (
            <Text dimColor>  +{files.length - 6} more</Text>
          )}
        </Box>
      )}
    </Box>
  );
};
