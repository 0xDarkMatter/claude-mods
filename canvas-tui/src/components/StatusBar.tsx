import React from 'react';
import { Box, Text } from 'ink';

interface StatusBarProps {
  status: 'waiting' | 'synced' | 'watching';
  timestamp: string | null;
  position: string | null;
  hints: string;
  width: number;
}

export const StatusBar: React.FC<StatusBarProps> = ({ status, timestamp, position, hints, width }) => {
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

  // Build left side: [icon] Synced: 09.01.2026 10:18am | Pos: [001-056/168]
  const leftParts = [`${statusLabel}:`];
  if (timestamp) leftParts.push(timestamp);
  if (position) leftParts.push('|', position);

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
          <Text color="white" dimColor>[</Text>
          <Text color={statusColor}>{statusIcon}</Text>
          <Text color="white" dimColor>] {leftParts.join(' ')}</Text>
        </Box>
        <Text color="white" dimColor>{hints}</Text>
      </Box>
    </Box>
  );
};
