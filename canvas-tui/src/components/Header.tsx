import React from 'react';
import { Box, Text } from 'ink';

interface HeaderProps {
  title: string;
  contentType: string;
  width: number;
}

export const Header: React.FC<HeaderProps> = ({ title, contentType, width }) => {
  const typeLabel = contentType.charAt(0).toUpperCase() + contentType.slice(1);
  const leftContent = ` ${title} `;
  const rightContent = ` ${typeLabel} `;

  // Calculate padding for centering
  const totalContentLength = leftContent.length + rightContent.length;
  const padding = Math.max(0, width - totalContentLength - 2);

  return (
    <Box borderStyle="single" borderBottom={true} borderTop={false} borderLeft={false} borderRight={false}>
      <Box width={width}>
        <Text bold color="blue">{leftContent}</Text>
        <Text>{' '.repeat(padding)}</Text>
        <Text color="gray">{rightContent}</Text>
      </Box>
    </Box>
  );
};
