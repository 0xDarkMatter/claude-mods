import React from 'react';
import { Box, Text } from 'ink';

interface StatusBarProps {
  status: 'waiting' | 'synced' | 'watching';
  message: string;
  hints: string;
  width: number;
}

export const StatusBar: React.FC<StatusBarProps> = ({ status, message, hints, width }) => {
  const statusColors: Record<string, string> = {
    waiting: 'yellow',
    synced: 'green',
    watching: 'cyan'
  };

  const statusIcons: Record<string, string> = {
    waiting: '...',
    synced: '***',
    watching: '>>>'
  };

  const statusColor = statusColors[status] || 'white';
  const statusIcon = statusIcons[status] || '?';

  return (
    <Box
      borderStyle="single"
      borderTop={true}
      borderBottom={false}
      borderLeft={false}
      borderRight={false}
      flexDirection="column"
    >
      <Box width={width} justifyContent="space-between">
        <Box>
          <Text color={statusColor}>[{statusIcon}]</Text>
          <Text> {message}</Text>
        </Box>
        <Text color="gray">{hints}</Text>
      </Box>
    </Box>
  );
};
