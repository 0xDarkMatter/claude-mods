import React from 'react';
import { Box, Text } from 'ink';

interface StatusBarProps {
  status: 'waiting' | 'synced' | 'watching';
  filename: string;
  timestamp: string | null;
  hints: string;
  width: number;
}

export const StatusBar: React.FC<StatusBarProps> = ({ status, filename, timestamp, hints, width }) => {
  const statusColors: Record<string, string> = {
    waiting: 'yellow',
    synced: 'green',
    watching: 'cyan'
  };

  const statusIcons: Record<string, string> = {
    waiting: '...',
    synced: '***',
    watching: '...'
  };

  const statusLabels: Record<string, string> = {
    waiting: 'Waiting',
    synced: 'Synced',
    watching: 'Watching'
  };

  const statusColor = statusColors[status] || 'white';
  const statusIcon = statusIcons[status] || ' ';
  const statusLabel = statusLabels[status] || '';
  const timeStr = timestamp ? ` ${timestamp}` : '';

  return (
    <Box
      borderStyle="single"
      borderTop={true}
      borderBottom={false}
      borderLeft={false}
      borderRight={false}
      borderDimColor
      flexDirection="column"
    >
      <Box width={width} justifyContent="space-between">
        <Box>
          <Text color={statusColor}>[{statusIcon}]</Text>
          <Text dimColor> {statusLabel}: {filename}{timeStr}</Text>
        </Box>
        <Text dimColor>{hints}</Text>
      </Box>
    </Box>
  );
};
